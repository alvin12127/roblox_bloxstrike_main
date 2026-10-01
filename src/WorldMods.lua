-- world mods: camera fov and no smoke
--   fov     : writes Camera.FieldOfView every frame, the original value is
--             remembered and restored when the feature is switched off.
--   no smoke: the dump shows every detonated smoke cloud as
--             Workspace.Debris.VoxelSmoke_<id>, a folder of SmokeVoxel parts with
--             particle emitters. Blanking the parts and disabling the emitters
--             removes the cloud on our client only.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local WorldMods = {
    Initialized = false,
    Connection = nil
}

local storedConfig = nil
local rememberedFov = nil
local smokeTimer = 0

local SMOKE_SCAN_INTERVAL = 0.5
local CLOUD_LIST_REFRESH = 1
local CLOUD_PREFIX = "voxelsmoke"

-- cloud folders are cached so the per frame pass is only property writes
local clouds = {}   -- [folder] = { descendants, refreshedAt }

local function findDebris()
    local debris = Workspace:FindFirstChild("Debris")
    if debris then return debris end

    return game:FindFirstChild("Debris")
end

local function isCloud(name)
    local lower = type(name) == "string" and name:lower() or ""
    return lower:sub(1, #CLOUD_PREFIX) == CLOUD_PREFIX
end

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

-- gathers the smoke cloud folders from both places they can live
local function collectClouds()
    local now = os.clock()

    local function consider(folder)
        if not isCloud(folder.Name) then return end

        local entry = clouds[folder]

        if (not entry) or ((now - entry.refreshedAt) >= CLOUD_LIST_REFRESH) then
            clouds[folder] = {
                descendants = folder:GetDescendants(),
                refreshedAt = now
            }
        end
    end

    local debris = findDebris()
    if debris then
        for _, child in ipairs(debris:GetChildren()) do
            pcall(consider, child)
        end
    end

    for _, child in ipairs(Workspace:GetChildren()) do
        pcall(consider, child)
    end

    -- drop clouds that no longer exist
    for folder in pairs(clouds) do
        if folder.Parent == nil then
            clouds[folder] = nil
        end
    end
end

-- applied every frame: the game animates these parts, so a slow refresh would
-- let the cloud flicker back in between scans
local function applyNoSmoke()
    for _, entry in pairs(clouds) do
        for _, desc in ipairs(entry.descendants) do
            pcall(function()
                if desc:IsA("ParticleEmitter") then
                    desc.Enabled = false
                elseif desc:IsA("BasePart") then
                    desc.Transparency = 1
                    desc.CastShadow = false
                elseif desc:IsA("ColorCorrectionEffect") then
                    desc.Enabled = false
                end
            end)
        end
    end
end

function WorldMods.init(Config)
    if WorldMods.Initialized then return end
    WorldMods.Initialized = true

    storedConfig = Config
    smokeTimer = 0

    WorldMods.Connection = RunService.RenderStepped:Connect(function()
        pcall(applyFov)

        if storedConfig and storedConfig.NO_SMOKE == true then
            local now = os.clock()

            if (now - smokeTimer) >= SMOKE_SCAN_INTERVAL then
                smokeTimer = now
                pcall(collectClouds)
            end

            pcall(applyNoSmoke)
        else
            if next(clouds) ~= nil then
                clouds = {}
            end
        end
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

    clouds = {}
    storedConfig = nil
    WorldMods.Initialized = false
end

return WorldMods
