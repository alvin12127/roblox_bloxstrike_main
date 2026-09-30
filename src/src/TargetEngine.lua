-- target selection and priority
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local InputController = nil
pcall(function()
    InputController = require(ReplicatedStorage.Controllers.InputController)
end)

-- fire input check
local function isShootingHeld()
    if InputController then
        local okAct, active = pcall(InputController.isActionActive, "Fire")
        if okAct and active == true then
            return true
        end

        local okPr, pressed = pcall(InputController.isActionPressed, "Fire")
        if okPr and pressed == true then
            return true
        end
    end

    if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
        return true
    end

    return false
end

local TargetEngine = {}

local targetHighlight = nil

local LETHAL_HEAD_PRIORITY = {"Head", "UpperTorso", "Torso", "LowerTorso", "RightUpperArm", "LeftUpperArm", "RightUpperLeg", "LeftUpperLeg"}
local LETHAL_TORSO_PRIORITY = {"UpperTorso", "Torso", "LowerTorso", "Head", "RightUpperArm", "LeftUpperArm", "RightUpperLeg", "LeftUpperLeg"}
local RANDOM_CANDIDATES = {"Head", "UpperTorso", "LowerTorso", "RightUpperArm", "LeftUpperArm", "RightUpperLeg", "LeftUpperLeg"}

local lastScanTime = 0
local lastScannedChar = nil
local cachedChosenPart = nil
local cachedOptimalPartName = "Head"

function TargetEngine.init(Config)
    targetHighlight = Instance.new("Highlight")
    targetHighlight.Name = "AG_TargetHighlight"
    targetHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    targetHighlight.FillTransparency = 1
    targetHighlight.OutlineTransparency = 0
    targetHighlight.OutlineColor = Config.BODYPART_HL_COLOR or Color3.fromRGB(255, 255, 0)
    targetHighlight.Enabled = false
    targetHighlight.Parent = Workspace
end

function TargetEngine.update(Config, Utils, DamageEngine)
    local isAimActive = (type(Config.isSilentAimActive) == "function") and Config.isSilentAimActive() or (Config.SILENT_AIM_ENABLED ~= false)
    if not isAimActive then
        Config.CurrentTargetChar = nil
        Config.CurrentTargetPart = nil
        Config.LockedTargetChar = nil
        Config.WaitingForM1Release = false
        if targetHighlight and targetHighlight.Enabled then
            targetHighlight.Enabled = false
        end
        return nil, nil
    end

    local vpCenter = Camera.ViewportSize * 0.5
    local charsFolder = Workspace:FindFirstChild("Characters")
    if not charsFolder then
        Config.CurrentTargetChar = nil
        Config.CurrentTargetPart = nil
        if targetHighlight and targetHighlight.Enabled then
            targetHighlight.Enabled = false
        end
        return nil, nil
    end

    local isShooting = isShootingHeld()
    local keepLock = (Config.KEEP_TARGET_LOCK ~= false)

    if not isShooting then
        Config.WaitingForM1Release = false
        Config.LockedTargetChar = nil
    end

    local selectedChar = nil

    if keepLock and isShooting and Config.WaitingForM1Release then
        selectedChar = nil
    else
        local lockedChar = Config.LockedTargetChar
        local lockedValid = false
        local camCFrame = Camera.CFrame
        local camPos = camCFrame.Position
        local camLook = camCFrame.LookVector
        local fovLimit = Config.FOV_DEG or 30

        local function getAngleDeg(targetPos)
            local dir = targetPos - camPos
            local mag = dir.Magnitude
            if mag == 0 then return 0 end
            local dot = math.clamp(camLook:Dot(dir / mag), -1, 1)
            return math.deg(math.acos(dot))
        end

        if keepLock and lockedChar and lockedChar.Parent == charsFolder and lockedChar.Name ~= LocalPlayer.Name then
            local isDead = (lockedChar:GetAttribute("Dead") == true)
            local hp = Utils.getCharacterHealth(lockedChar)
            if not isDead and hp > 0 then
                local p = Players:FindFirstChild(lockedChar.Name)
                if Utils.isEnemy(p, lockedChar) then
                    local head = lockedChar:FindFirstChild("Head")
                    if head and head:IsA("BasePart") then
                        local angle = getAngleDeg(head.Position)
                        if fovLimit >= 180 or angle <= fovLimit then
                            lockedValid = true
                        end
                    end
                end
            end
        end

        if keepLock and isShooting and lockedValid then
            selectedChar = lockedChar
        elseif keepLock and isShooting and lockedChar and not lockedValid then
            Config.WaitingForM1Release = true
            Config.LockedTargetChar = nil
            selectedChar = nil
        else
            local bestHead = nil
            local bestChar = nil
            local bestAngle = math.huge

            for _, char in ipairs(charsFolder:GetChildren()) do
                if char:IsA("Model") and char.Parent == charsFolder and char.Name ~= LocalPlayer.Name then
                    local isDead = (char:GetAttribute("Dead") == true)
                    local hp = Utils.getCharacterHealth(char)

                    if not isDead and hp > 0 then
                        local p = Players:FindFirstChild(char.Name)
                        if Utils.isEnemy(p, char) then
                            local head = char:FindFirstChild("Head")
                            if head and head:IsA("BasePart") then
                                local angle = getAngleDeg(head.Position)
                                if (fovLimit >= 180 or angle <= fovLimit) and angle < bestAngle then
                                    bestAngle = angle
                                    bestHead = head
                                    bestChar = char
                                end
                            end
                        end
                    end
                end
            end

            selectedChar = bestChar

            if keepLock and isShooting and selectedChar then
                Config.LockedTargetChar = selectedChar
            end
        end
    end

    Config.CurrentTargetChar = selectedChar
    Config.CurrentTargetPart = nil

    local optimalPartName = "Head"

    if Config.CurrentTargetChar and Config.CurrentTargetChar.Parent == charsFolder then
        local now = os.clock()
        local priorityMode = Config.TARGET_PRIORITY or "Auto"
        local shouldRescan = (Config.CurrentTargetChar ~= lastScannedChar) or ((now - lastScanTime) > 0.08)

        if shouldRescan then
            lastScanTime = now
            lastScannedChar = Config.CurrentTargetChar

            local myChar = Utils.getAliveCharacter(LocalPlayer)
            local distance = 0
            if myChar and myChar:FindFirstChild("Head") and Config.CurrentTargetChar:FindFirstChild("Head") then
                distance = (Config.CurrentTargetChar.Head.Position - myChar.Head.Position).Magnitude
            end

            local hp = Utils.getCharacterHealth(Config.CurrentTargetChar)
            local weaponName = DamageEngine.getCurrentWeapon()
            local weaponCfg = weaponName and DamageEngine.getWeaponConfig(weaponName)
            local targetPlr = Players:FindFirstChild(Config.CurrentTargetChar.Name)

            local chosenPart = nil

            if priorityMode == "Head" then
                chosenPart = Config.CurrentTargetChar:FindFirstChild("Head")
                    or Config.CurrentTargetChar:FindFirstChild("UpperTorso")
                optimalPartName = "Head"
            elseif priorityMode == "Torso" then
                chosenPart = Config.CurrentTargetChar:FindFirstChild("UpperTorso")
                    or Config.CurrentTargetChar:FindFirstChild("Torso")
                    or Config.CurrentTargetChar:FindFirstChild("LowerTorso")
                    or Config.CurrentTargetChar:FindFirstChild("HumanoidRootPart")
                optimalPartName = "Torso"
            elseif priorityMode == "Random" then
                local validCandidates = {}
                for _, name in ipairs(RANDOM_CANDIDATES) do
                    local p = Config.CurrentTargetChar:FindFirstChild(name)
                    if p and p:IsA("BasePart") then
                        table.insert(validCandidates, p)
                    end
                end
                if #validCandidates > 0 then
                    local visibleCandidates = {}
                    for _, p in ipairs(validCandidates) do
                        if not Utils.isPartOccluded(p, Config.CurrentTargetChar) then
                            table.insert(visibleCandidates, p)
                        end
                    end
                    local pool = (#visibleCandidates > 0) and visibleCandidates or validCandidates
                    chosenPart = pool[math.random(1, #pool)]
                    optimalPartName = (chosenPart.Name == "Head") and "Head" or "Torso"
                end
            else
                local lethalPref = DamageEngine.getOptimalTargetPart(weaponCfg, Config.CurrentTargetChar, targetPlr, distance, hp, Config.FALLOFF_REF)
                local priorityList = (lethalPref == "Torso") and LETHAL_TORSO_PRIORITY or LETHAL_HEAD_PRIORITY

                for _, partName in ipairs(priorityList) do
                    local p = Config.CurrentTargetChar:FindFirstChild(partName)
                    if p and p:IsA("BasePart") then
                        if not Utils.isPartOccluded(p, Config.CurrentTargetChar) then
                            chosenPart = p
                            break
                        end
                    end
                end

                if not chosenPart then
                    if lethalPref == "Torso" then
                        chosenPart = Config.CurrentTargetChar:FindFirstChild("UpperTorso")
                            or Config.CurrentTargetChar:FindFirstChild("Torso")
                            or Config.CurrentTargetChar:FindFirstChild("LowerTorso")
                            or Config.CurrentTargetChar:FindFirstChild("Head")
                    else
                        chosenPart = Config.CurrentTargetChar:FindFirstChild("Head")
                            or Config.CurrentTargetChar:FindFirstChild("UpperTorso")
                    end
                end

                optimalPartName = (chosenPart and chosenPart.Name == "Head") and "Head" or "Torso"
            end

            cachedChosenPart = chosenPart or Config.CurrentTargetChar:FindFirstChild("Head")
            cachedOptimalPartName = optimalPartName
        end

        Config.CurrentTargetPart = cachedChosenPart or Config.CurrentTargetChar:FindFirstChild("Head")
    else
        lastScannedChar = nil
        cachedChosenPart = nil
    end

    -- target part highlight
    local isAimActive = (type(Config.isSilentAimActive) == "function") and Config.isSilentAimActive() or (Config.SILENT_AIM_ENABLED ~= false)
    local canShowTargetHl = (Config.ESP_ENABLED ~= false) and Config.BODYPART_TARGET_HL and isAimActive
    if canShowTargetHl and Config.CurrentTargetPart and Config.CurrentTargetPart:IsDescendantOf(charsFolder) then
        if targetHighlight then
            if targetHighlight.Adornee ~= Config.CurrentTargetPart then
                targetHighlight.Adornee = Config.CurrentTargetPart
            end
            if not targetHighlight.Enabled then
                targetHighlight.Enabled = true
            end
        end
    else
        if targetHighlight and targetHighlight.Enabled then
            targetHighlight.Enabled = false
        end
    end

    return Config.CurrentTargetChar, Config.CurrentTargetPart
end

function TargetEngine.cleanup()
    if targetHighlight then
        pcall(function() targetHighlight:Destroy() end)
        targetHighlight = nil
    end
end

return TargetEngine
