-- utilities
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

local Utils = {}

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

function Utils.getAliveCharacter(player)
    if not player then return nil end
    local chars = Workspace:FindFirstChild("Characters")
    if not chars then return nil end
    
    local char = chars:FindFirstChild(player.Name)
    if char and char:IsA("Model") and char.Parent == chars then
        if char:GetAttribute("Dead") ~= true then
            return char
        end
    end
    return nil
end

function Utils.getTeam(player, char)
    if not char and player then
        char = Utils.getAliveCharacter(player)
    end
    if player then
        local t = player:GetAttribute("Team") or player:GetAttribute("TeamName")
        if t and (t == "Counter-Terrorists" or t == "CT" or t == "Terrorists" or t == "T") then
            return t
        end
    end
    if char then
        local t = char:GetAttribute("Team") or char:GetAttribute("TeamName")
        if t and (t == "Counter-Terrorists" or t == "CT" or t == "Terrorists" or t == "T") then
            return t
        end
        local head = char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
        if head and head:IsA("BasePart") then
            local cg = head.CollisionGroup
            if cg == "Counter-Terrorists" or cg == "CT" or cg == "Terrorists" or cg == "T" then
                return cg
            end
        end
        local parent = char.Parent
        if parent and (parent.Name == "Counter-Terrorists" or parent.Name == "Terrorists") then
            return parent.Name
        end
    end
    return nil
end

function Utils.getMyTeam()
    local myChar = Utils.getAliveCharacter(LocalPlayer) or LocalPlayer.Character
    return Utils.getTeam(LocalPlayer, myChar)
end

function Utils.isEnemy(player, char)
    local myTeam = Utils.getMyTeam()
    local theirTeam = Utils.getTeam(player, char)
    if not theirTeam then return false end
    if not myTeam then return true end
    return myTeam ~= theirTeam
end

function Utils.getCharacterHealth(char)
    if not char or not char.Parent then return 0, 100 end

    local charsFolder = Workspace:FindFirstChild("Characters")
    if char.Parent ~= charsFolder and (not char.Parent.Parent or char.Parent.Parent ~= charsFolder) then
        return 0, 100
    end

    if char:GetAttribute("Dead") == true then
        return 0, 100
    end

    local hp = tonumber(char:GetAttribute("Health"))
    local maxHp = tonumber(char:GetAttribute("MaxHealth"))

    if not hp or hp <= 0 then
        local p = Players:FindFirstChild(char.Name)
        if p and p:GetAttribute("Dead") == true then
            return 0, 100
        end
        local humanoid = char:FindFirstChildOfClass("Humanoid")
        if humanoid and humanoid.Health > 0 then
            hp = tonumber(humanoid.Health)
            maxHp = tonumber(humanoid.MaxHealth)
        end
    end

    hp = (hp and hp > 0) and hp or 100
    maxHp = (maxHp and maxHp > 0) and maxHp or 100

    return hp, maxHp
end

local cachedMyChar = nil
local cachedCam = nil

-- occlusion check to part
function Utils.isPartOccluded(part, targetChar)
    if not part then return true end

    local cam = Workspace.CurrentCamera
    local origin = cam.CFrame.Position
    local targetPos = part.Position
    local direction = targetPos - origin

    local myChar = LocalPlayer.Character
    if myChar ~= cachedMyChar or cam ~= cachedCam then
        cachedMyChar = myChar
        cachedCam = cam
        rayParams.FilterDescendantsInstances = myChar and {myChar, cam} or {cam}
    end

    local result = Workspace:Raycast(origin, direction, rayParams)
    if not result then
        return false
    end

    if result.Instance == part or (targetChar and result.Instance:IsDescendantOf(targetChar)) then
        return false
    end

    return true
end

-- occlusion check to character
function Utils.isTargetOccluded(char)
    if not char then return true end
    local part = char:FindFirstChild("Head") or char:FindFirstChild("UpperTorso")
    return Utils.isPartOccluded(part, char)
end

local HITBOX_NAMES = {
    "Head", "UpperTorso", "LowerTorso", "Torso", "HumanoidRootPart",
    "LeftUpperArm", "LeftLowerArm", "LeftHand", "Left Arm",
    "RightUpperArm", "RightLowerArm", "RightHand", "Right Arm",
    "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "Left Leg",
    "RightUpperLeg", "RightLowerLeg", "RightFoot", "Right Leg"
}

-- check if all hitboxes of character are occluded
function Utils.areAllHitboxesOccluded(char)
    if not char then return true end
    local foundHitbox = false
    for _, name in ipairs(HITBOX_NAMES) do
        local p = char:FindFirstChild(name)
        if p and p:IsA("BasePart") then
            foundHitbox = true
            if not Utils.isPartOccluded(p, char) then
                return false
            end
        end
    end
    if not foundHitbox then
        for _, child in ipairs(char:GetChildren()) do
            if child:IsA("BasePart") then
                if not Utils.isPartOccluded(child, char) then
                    return false
                end
            end
        end
    end
    return true
end

return Utils
