-- world mods: camera field of view
-- Writes Camera.FieldOfView every frame. The original value is remembered the
-- first time the override is applied and restored again when the feature is
-- switched off, so the game's own camera setup is never permanently disturbed.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local WorldMods = {
    Initialized = false,
    Connection = nil
}

local storedConfig = nil
local rememberedFov = nil

local function applyFov()
    local camera = Workspace.CurrentCamera
    if not camera then return end

    if storedConfig and storedConfig.CAMERA_FOV_ENABLED then
        if rememberedFov == nil then
            rememberedFov = camera.FieldOfView
        end

        local value = tonumber(storedConfig.CAMERA_FOV_VALUE) or 90
        camera.FieldOfView = math.clamp(value, 30, 120)
    elseif rememberedFov ~= nil then
        camera.FieldOfView = rememberedFov
        rememberedFov = nil
    end
end

function WorldMods.init(Config)
    if WorldMods.Initialized then return end
    WorldMods.Initialized = true

    storedConfig = Config

    WorldMods.Connection = RunService.RenderStepped:Connect(function()
        pcall(applyFov)
    end)
end

function WorldMods.cleanup()
    if WorldMods.Connection then
        pcall(function() WorldMods.Connection:Disconnect() end)
        WorldMods.Connection = nil
    end

    if rememberedFov ~= nil then
        pcall(function()
            local camera = Workspace.CurrentCamera
            if camera then camera.FieldOfView = rememberedFov end
        end)
        rememberedFov = nil
    end

    storedConfig = nil
    WorldMods.Initialized = false
end

return WorldMods
