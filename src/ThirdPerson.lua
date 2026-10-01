-- third person camera
-- Ported as-is from the reference source. Two pieces work together:
--
--   1) a __newindex hook on the game metatable. Roblox routes every property
--      write on every Instance through this metamethod, so the game can be
--      silently prevented from pushing CameraMode back to LockFirstPerson (and
--      from resetting the zoom limits) whenever it sets up the view.
--
--   2) a per frame write of CameraMode = Classic plus CameraMin/MaxZoomDistance
--      pinned to the same number. Equal min and max is what locks the camera at
--      exactly that distance behind the character.
--
-- Nothing here touches Camera.CFrame or the character rig, which is why the
-- character no longer gets dragged along with the view.

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

-- installs the metamethod guard once
local function installMetaHook()
    if metaHooked then return end
    if not (getrawmetatable and setreadonly and newcclosure) then return end

    local ok, mt = pcall(getrawmetatable, game)
    if (not ok) or (type(mt) ~= "table") then return end

    local oldNewIndex = mt.__newindex
    if type(oldNewIndex) ~= "function" then return end

    originalNewIndex = oldNewIndex
    metaHooked = true

    setreadonly(mt, false)

    mt.__newindex = newcclosure(function(self, key, value)
        if self == LocalPlayer and storedConfig and storedConfig.THIRDPERSON_ENABLED then
            local dist = math.clamp(storedConfig.THIRDPERSON_DISTANCE or 10, 5, 50)

            if key == "CameraMode" then
                return oldNewIndex(self, key, Enum.CameraMode.Classic)
            elseif key == "CameraMaxZoomDistance" then
                return oldNewIndex(self, key, dist)
            elseif key == "CameraMinZoomDistance" then
                return oldNewIndex(self, key, dist)
            end
        end

        return oldNewIndex(self, key, value)
    end)

    setreadonly(mt, true)
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

    -- same as the reference: install the guard off the main path
    task.spawn(function()
        pcall(installMetaHook)
    end)

    ThirdPerson.Connection = RunService.RenderStepped:Connect(function()
        pcall(function()
            if (not storedConfig) or (not storedConfig.THIRDPERSON_ENABLED) then
                -- same as the reference toggle callback: drop back to first
                -- person once, instead of writing it every frame
                if not forcedFirstPerson then
                    forcedFirstPerson = true
                    LocalPlayer.CameraMode = Enum.CameraMode.LockFirstPerson
                end
                return
            end

            forcedFirstPerson = false

            local clampedDist = math.clamp(storedConfig.THIRDPERSON_DISTANCE or 10, 5, 50)

            LocalPlayer.CameraMode = Enum.CameraMode.Classic
            LocalPlayer.CameraMaxZoomDistance = clampedDist
            LocalPlayer.CameraMinZoomDistance = clampedDist
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
