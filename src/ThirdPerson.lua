-- third person camera
-- method "Offset": Roblox's own camera controller pulls the view back through
-- Humanoid.CameraOffset. This never touches the rig, does not fight any camera
-- script and handles wall clipping on its own.
-- method "Push": the older local hack that overwrites Camera.CFrame every frame.
-- It works on any game but may look odd and does not respect walls.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

local ThirdPerson = {
    Initialized = false,
    Connection = nil
}

local storedConfig = nil
local previousCameraMode = nil

local function getHumanoid()
    local char = LocalPlayer.Character
    if not char or char.Parent == nil then return nil end
    return char:FindFirstChildOfClass("Humanoid")
end

local function restoreOnce()
    if previousCameraMode ~= nil then
        pcall(function() LocalPlayer.CameraMode = previousCameraMode end)
        previousCameraMode = nil
    end

    local humanoid = getHumanoid()
    if humanoid then
        pcall(function() humanoid.CameraOffset = Vector3.zero end)
    end
end

local function applyOffset(config)
    local humanoid = getHumanoid()
    if not humanoid then return end

    -- LockFirstPerson refuses any offset, so classic mode has to be active
    if LocalPlayer.CameraMode ~= Enum.CameraMode.Classic then
        if previousCameraMode == nil then
            previousCameraMode = LocalPlayer.CameraMode
        end
        pcall(function() LocalPlayer.CameraMode = Enum.CameraMode.Classic end)
    end

    local distance = tonumber(config.THIRDPERSON_DISTANCE) or 9
    local height = tonumber(config.THIRDPERSON_HEIGHT) or 0

    humanoid.CameraOffset = Vector3.new(0, height, -distance)
end

-- fallback that works even when the game drives a Scriptable camera
local function applyPush(config)
    local char = LocalPlayer.Character
    if not char or char.Parent == nil then return end
    if char:GetAttribute("Dead") == true then return end

    local root = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("UpperTorso")
    if not root or not root:IsA("BasePart") then return end

    local ok, rotation = pcall(function() return Workspace.CurrentCamera.CFrame.Rotation end)
    if not ok or not rotation then return end

    local head = char:FindFirstChild("Head")
    local headOffsetY = head and (head.Position.Y - root.Position.Y) or 0

    local distance = tonumber(config.THIRDPERSON_DISTANCE) or 9
    local height = tonumber(config.THIRDPERSON_HEIGHT) or 0
    local camera = Workspace.CurrentCamera

    local anchor = root.Position + Vector3.new(0, headOffsetY + height, 0)
    local position = anchor + (rotation.LookVector * -distance)

    if camera then
        pcall(function() camera.CFrame = CFrame.new(position) * rotation end)
    end
end

local function onFrame()
    local config = storedConfig
    if not config then return end

    if config.THIRDPERSON_ENABLED ~= true then
        restoreOnce()
        return
    end

    if (config.THIRDPERSON_METHOD or "Offset") == "Offset" then
        applyOffset(config)
    else
        applyPush(config)
    end
end

function ThirdPerson.init(Config)
    if ThirdPerson.Initialized then return end
    ThirdPerson.Initialized = true

    storedConfig = Config

    ThirdPerson.Connection = RunService.RenderStepped:Connect(function()
        pcall(onFrame)
    end)
end

function ThirdPerson.cleanup()
    if ThirdPerson.Connection then
        pcall(function() ThirdPerson.Connection:Disconnect() end)
        ThirdPerson.Connection = nil
    end

    restoreOnce()
    storedConfig = nil
    ThirdPerson.Initialized = false
end

return ThirdPerson
