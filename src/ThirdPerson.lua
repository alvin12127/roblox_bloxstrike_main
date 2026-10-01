-- third person camera
-- method "Push": overwrites Camera.CFrame each frame. This game runs a custom
-- (ClassicCamera) controller, so Humanoid.CameraOffset has no effect here and
-- Push is what actually moves the view behind the rig.
-- method "Offset": the native Humanoid.CameraOffset route, kept for games that
-- do respect it.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

local ThirdPerson = {
    Initialized = false,
    Connection = nil
}

local storedConfig = nil
local previousCameraMode = nil
local clipParams = RaycastParams.new()
clipParams.FilterType = Enum.RaycastFilterType.Exclude
clipParams.IgnoreWater = true

-- keeps the camera in front of geometry instead of letting it slide through walls
local function clipDistance(anchor, direction, distance)
    local camera = Workspace.CurrentCamera
    if not camera then return distance end

    local character = LocalPlayer.Character or camera
    if clipParams.FilterDescendantsInstances[1] ~= character then
        clipParams.FilterDescendantsInstances = character and { character, camera } or { camera }
    end

    local ok, result = pcall(Workspace.Raycast, Workspace, anchor, direction * distance, clipParams)
    if ok and result and result.Distance then
        return math.max(result.Distance - 0.6, 2)
    end

    return distance
end

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

    local camera = Workspace.CurrentCamera
    if not camera then return end

    local ok, rotation = pcall(function() return camera.CFrame.Rotation end)
    if not ok or not rotation then return end

    local head = char:FindFirstChild("Head")
    local headOffsetY = head and (head.Position.Y - root.Position.Y) or 0

    local distanceRaw = tonumber(config.THIRDPERSON_DISTANCE) or 9
    local height = tonumber(config.THIRDPERSON_HEIGHT) or 0

    local anchor = root.Position + Vector3.new(0, headOffsetY + height, 0)
    local direction = rotation.LookVector * -1

    local distance = clipDistance(anchor, direction, distanceRaw)
    local position = anchor + (direction * distance)

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
