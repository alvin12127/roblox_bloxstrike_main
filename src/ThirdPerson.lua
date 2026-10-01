-- third person camera
-- Instead of hooking __newindex (which breaks other scripts' Instance writes),
-- we watch CameraMode changes via GetPropertyChangedSignal and immediately
-- restore Classic. This never touches the global metatable, so damage dealing,
-- ESP, and every other feature keeps working while third person is active.
--
-- How it works:
--   1) RenderStepped writes CameraMode=Classic and pins zoom limits each frame
--   2) A PropertyChangedSignal on CameraMode restores Classic the instant the
--      game tries to force LockFirstPerson back, even between our frames.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

local ThirdPerson = {
    Initialized = false,
    Connection = nil,
    ModeWatch = nil
}

local storedConfig = nil
local forcedFirstPerson = false

local function isEnabled()
    return storedConfig and storedConfig.THIRDPERSON_ENABLED == true
end

local function currentDistance()
    return math.clamp(tonumber(storedConfig and storedConfig.THIRDPERSON_DISTANCE) or 10, 5, 50)
end

local function forceClassic()
    pcall(function()
        if LocalPlayer.CameraMode ~= Enum.CameraMode.Classic then
            LocalPlayer.CameraMode = Enum.CameraMode.Classic
        end
        local dist = currentDistance()
        if LocalPlayer.CameraMaxZoomDistance ~= dist then
            LocalPlayer.CameraMaxZoomDistance = dist
        end
        if LocalPlayer.CameraMinZoomDistance ~= dist then
            LocalPlayer.CameraMinZoomDistance = dist
        end
    end)
end

-- Watch CameraMode so we restore Classic the instant the game overrides us.
-- This replaces the old __newindex metatable hook entirely.
local function startModeWatch()
    if ThirdPerson.ModeWatch then return end

    pcall(function()
        ThirdPerson.ModeWatch = LocalPlayer:GetPropertyChangedSignal("CameraMode"):Connect(function()
            if isEnabled() and LocalPlayer.CameraMode ~= Enum.CameraMode.Classic then
                forceClassic()
            end
        end)
    end)
end

local function stopModeWatch()
    if ThirdPerson.ModeWatch then
        pcall(function() ThirdPerson.ModeWatch:Disconnect() end)
        ThirdPerson.ModeWatch = nil
    end
end

function ThirdPerson.init(Config)
    if ThirdPerson.Initialized then return end
    ThirdPerson.Initialized = true

    storedConfig = Config

    startModeWatch()

    ThirdPerson.Connection = RunService.RenderStepped:Connect(function()
        pcall(function()
            if not isEnabled() then
                if not forcedFirstPerson then
                    forcedFirstPerson = true
                    LocalPlayer.CameraMode = Enum.CameraMode.LockFirstPerson
                end
                stopModeWatch()
                return
            end

            forcedFirstPerson = false
            startModeWatch()
            forceClassic()
        end)
    end)
end

function ThirdPerson.disable()
    pcall(function()
        LocalPlayer.CameraMode = Enum.CameraMode.LockFirstPerson
    end)
end

function ThirdPerson.cleanup()
    if ThirdPerson.Connection then
        pcall(function() ThirdPerson.Connection:Disconnect() end)
        ThirdPerson.Connection = nil
    end

    stopModeWatch()
    ThirdPerson.disable()

    storedConfig = nil
    ThirdPerson.Initialized = false
end

return ThirdPerson