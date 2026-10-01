-- third person camera
-- Ported from the reference source, with one important change: the __newindex
-- metamethod guard is installed ONLY while the feature is enabled.
--
-- Replacing mt.__newindex intercepts the property write of every Instance in the
-- game. Roblox's original __newindex performs a capability check on the calling
-- thread, and any script running on a thread without the Plugin capability then
-- fails with
--     "The current thread cannot access 'Instance' (lacking capability Plugin)"
-- which is exactly what happened to the loader when it updated its status label
-- from a task.spawn thread. With the feature off the metatable is left untouched,
-- so nothing else in the game is affected.
--
-- How it works:
--   1) while enabled, the guard rewrites CameraMode to Classic and pins both
--      zoom limits to the same distance, so the game cannot push the view back
--      into first person between our own writes.
--   2) a per frame write of the same three properties does the actual work.
--      Equal min and max zoom is what locks the camera at exactly that distance
--      behind the character.
--
-- Nothing here touches Camera.CFrame or the character rig.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

local ThirdPerson = {
    Initialized = false,
    Connection = nil
}

local storedConfig = nil
local metaHooked = false
local originalNewIndex = nil
local forcedFirstPerson = false

local function isEnabled()
    return storedConfig and storedConfig.THIRDPERSON_ENABLED == true
end

-- the metamethod guard is what keeps the game from forcing first person back.
-- It can be turned off if it ever interferes with another script.
local function guardAllowed()
    return storedConfig and storedConfig.THIRDPERSON_GUARD ~= false
end

local function currentDistance()
    return math.clamp(tonumber(storedConfig and storedConfig.THIRDPERSON_DISTANCE) or 10, 5, 50)
end

local function installMetaHook()
    if metaHooked then return end
    if not (getrawmetatable and setreadonly and newcclosure) then return end

    local ok, mt = pcall(getrawmetatable, game)
    if (not ok) or (type(mt) ~= "table") then return end

    local oldNewIndex = mt.__newindex
    if type(oldNewIndex) ~= "function" then return end

    originalNewIndex = oldNewIndex
    metaHooked = true

    pcall(function()
        setreadonly(mt, false)

        mt.__newindex = newcclosure(function(self, key, value)
            -- Only the local player's camera properties are ever rewritten
            if self == LocalPlayer and isEnabled() then
                if key == "CameraMode" then
                    value = Enum.CameraMode.Classic
                elseif key == "CameraMaxZoomDistance" or key == "CameraMinZoomDistance" then
                    value = currentDistance()
                end
            end

            -- The original metamethod checks the caller's capabilities, so this
            -- can legitimately fail on a restricted thread. Swallowing it keeps
            -- a third person write from ever breaking an unrelated script.
            local okWrite, result = pcall(oldNewIndex, self, key, value)
            if okWrite then
                return result
            end
            return nil
        end)

        setreadonly(mt, true)
    end)
end

local function restoreMetaHook()
    if (not metaHooked) or (not originalNewIndex) then return end

    pcall(function()
        local ok, mt = pcall(getrawmetatable, game)
        if ok and type(mt) == "table" then
            setreadonly(mt, false)
            mt.__newindex = originalNewIndex
            setreadonly(mt, true)
        end
    end)

    metaHooked = false
    originalNewIndex = nil
end

function ThirdPerson.init(Config)
    if ThirdPerson.Initialized then return end
    ThirdPerson.Initialized = true

    storedConfig = Config

    ThirdPerson.Connection = RunService.RenderStepped:Connect(function()
        pcall(function()
            if not isEnabled() then
                -- the guard is only needed while the feature is on
                if metaHooked then
                    restoreMetaHook()
                end

                -- same as the reference toggle callback: drop back to first
                -- person once, instead of writing it every frame
                if not forcedFirstPerson then
                    forcedFirstPerson = true
                    LocalPlayer.CameraMode = Enum.CameraMode.LockFirstPerson
                end
                return
            end

            forcedFirstPerson = false

            if not guardAllowed() then
                if metaHooked then
                    restoreMetaHook()
                end
            elseif not metaHooked then
                installMetaHook()
            end

            local dist = currentDistance()

            LocalPlayer.CameraMode = Enum.CameraMode.Classic
            LocalPlayer.CameraMaxZoomDistance = dist
            LocalPlayer.CameraMinZoomDistance = dist
        end)
    end)
end

-- mirrors the reference toggle callback: force first person back on disable
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

    restoreMetaHook()
    ThirdPerson.disable()

    storedConfig = nil
    ThirdPerson.Initialized = false
end

return ThirdPerson
