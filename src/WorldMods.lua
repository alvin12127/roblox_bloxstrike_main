-- world mods: camera fov, lighting/world tweaks and post processing
--
-- A single RenderStepped loop applies everything. Every feature remembers the
-- value it overwrote the first time it touches something, and cleanup() puts
-- all of those originals back, so toggling a feature off - or unloading the
-- script - never leaves the game permanently modified.
--
-- Two things are deliberately done ONCE instead of every frame, because writing
-- them per frame is wasteful and would fight whatever else touches the instance:
--   * material / texture and colour edits on map parts, guarded by appliedMap
--   * creating Sky and post processing instances, guarded by WorldMods.Effects
--
-- Several features write the same Lighting property. They are applied in a fixed
-- order further down and the last writer of a frame wins, which is deterministic:
--   clock -> brightness -> ambient -> outdoor ambient -> map colour -> fullbright
--
-- Map parts means every BasePart/MeshPart under Workspace except Terrain and
-- anything below Workspace.Characters, which is where the player models live.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local WorldMods = {
    Initialized = false,
    Connection = nil,
    Effects = {},
    Cache = {
        Lighting = {},
        Parts = {}
    }
}

local storedConfig = nil
local rememberedFov = nil

-- features that rewrite whole instances instead of single values are applied
-- once; these flags say whether that has already happened
local appliedMap = {
    Textures = false,
    Tint = false
}

-- map colour mode names, also used to reject unknown values
local VALID_MAP_MODES = {
    Tint = true,
    Ambient = true,
    Both = true,
    Saturation = true
}

----------------------------------------------------------------------
-- config reading. Every read falls back to a default.
----------------------------------------------------------------------

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

local function cfgValue(key)
    if type(storedConfig) ~= "table" then return nil end
    return storedConfig[key]
end

local function cfgBool(key)
    return cfgValue(key) == true
end

local function cfgNumber(key, default)
    local value = tonumber(cfgValue(key))
    if (value == nil) or (value ~= value) then return default end
    return value
end

local function cfgString(key, default)
    local value = cfgValue(key)
    if type(value) ~= "string" or value == "" then return default end
    return value
end

local function cfgColor(key, defaultR, defaultG, defaultB)
    local raw = cfgValue(key)
    if type(raw) ~= "table" then
        return Color3.fromRGB(defaultR, defaultG, defaultB)
    end

    local r = tonumber(raw.r) or tonumber(raw[1]) or defaultR
    local g = tonumber(raw.g) or tonumber(raw[2]) or defaultG
    local b = tonumber(raw.b) or tonumber(raw[3]) or defaultB

    return Color3.fromRGB(
        math.floor(clamp(r, 0, 255) + 0.5),
        math.floor(clamp(g, 0, 255) + 0.5),
        math.floor(clamp(b, 0, 255) + 0.5)
    )
end

----------------------------------------------------------------------
-- Lighting cache. Values are remembered once, before the first overwrite,
-- so restoring always brings back what the game itself was using.
----------------------------------------------------------------------

local function rememberLighting(property)
    local store = WorldMods.Cache.Lighting
    if store[property] == nil then
        pcall(function() store[property] = Lighting[property] end)
    end
end

local function setLighting(property, value)
    pcall(function()
        rememberLighting(property)
        Lighting[property] = value
    end)
end

local function restoreLightingProperty(property)
    local store = WorldMods.Cache.Lighting
    local value = store[property]
    if value == nil then return end

    pcall(function() Lighting[property] = value end)
    store[property] = nil
end

local function restoreAllLighting()
    local store = WorldMods.Cache.Lighting
    for property, value in pairs(store) do
        pcall(function() Lighting[property] = value end)
        store[property] = nil
    end
end

----------------------------------------------------------------------
-- map parts
----------------------------------------------------------------------

local function forEachMapPart(callback)
    pcall(function()
        local characters = Workspace:FindFirstChild("Characters")

        for _, part in ipairs(Workspace:GetDescendants()) do
            if part:IsA("BasePart") or part:IsA("MeshPart") then
                if not part:IsA("Terrain") then
                    local isCharacterPart = characters ~= nil and part:IsDescendantOf(characters)
                    if not isCharacterPart then
                        callback(part)
                    end
                end
            end
        end
    end)
end

local function rememberPart(part, property)
    local store = WorldMods.Cache.Parts
    local entry = store[part]
    if entry == nil then
        entry = {}
        store[part] = entry
    end

    if entry[property] == nil then
        entry[property] = part[property]
    end
end

local function setPartProperty(part, property, value)
    pcall(function()
        rememberPart(part, property)
        part[property] = value
    end)
end

local function restorePartProperty(property)
    local store = WorldMods.Cache.Parts

    for part, entry in pairs(store) do
        local value = entry[property]
        if value ~= nil then
            pcall(function() part[property] = value end)
            entry[property] = nil
        end

        if next(entry) == nil then
            store[part] = nil
        end
    end
end

local function restoreAllParts()
    local store = WorldMods.Cache.Parts

    for part, entry in pairs(store) do
        for property, value in pairs(entry) do
            pcall(function() part[property] = value end)
            entry[property] = nil
        end
        store[part] = nil
    end
end

----------------------------------------------------------------------
-- instance helpers for Sky / post processing effects
----------------------------------------------------------------------

local function destroyEffect(name)
    local effect = WorldMods.Effects[name]
    if effect == nil then return end

    pcall(function() effect:Destroy() end)
    WorldMods.Effects[name] = nil
end

-- returns the cached instance, creating it once if it is missing
local function getEffect(name, className)
    local existing = WorldMods.Effects[name]
    if existing ~= nil then
        local alive = false
        pcall(function() alive = existing.Parent ~= nil end)
        if alive then return existing end
        WorldMods.Effects[name] = nil
    end

    local created = nil
    pcall(function()
        created = Instance.new(className)
        created.Name = "WorldMods_" .. name
        created.Parent = Lighting
    end)

    if created ~= nil then
        WorldMods.Effects[name] = created
    end

    return WorldMods.Effects[name]
end

local function applyEffect(name, className, enabled, configure)
    if not enabled then
        destroyEffect(name)
        return
    end

    local effect = getEffect(name, className)
    if effect == nil then return end

    pcall(function() configure(effect) end)
end

----------------------------------------------------------------------
-- camera fov
----------------------------------------------------------------------

local function applyFov()
    local camera = Workspace.CurrentCamera
    if not camera then return end

    if cfgBool("CAMERA_FOV_ENABLED") then
        if rememberedFov == nil then
            rememberedFov = camera.FieldOfView
        end

        local value = cfgNumber("CAMERA_FOV_VALUE", 90)
        camera.FieldOfView = clamp(value, 30, 120)
    elseif rememberedFov ~= nil then
        camera.FieldOfView = rememberedFov
        rememberedFov = nil
    end
end

----------------------------------------------------------------------
-- simple Lighting values
----------------------------------------------------------------------

local function applyClockTime()
    if cfgBool("CLOCK_TIME_ENABLED") then
        setLighting("ClockTime", clamp(cfgNumber("CLOCK_TIME", 14), 0, 24))
    else
        restoreLightingProperty("ClockTime")
    end
end

local function applyBrightness()
    if cfgBool("BRIGHTNESS_ENABLED") then
        setLighting("Brightness", cfgNumber("BRIGHTNESS", 2))
    else
        restoreLightingProperty("Brightness")
    end
end

local function applyAmbient()
    if cfgBool("AMBIENT_ENABLED") then
        setLighting("Ambient", cfgColor("AMBIENT_COLOR", 100, 100, 100))
    else
        restoreLightingProperty("Ambient")
    end
end

local function applyOutdoorAmbient()
    if cfgBool("OUTDOOR_AMBIENT_ENABLED") then
        setLighting("OutdoorAmbient", cfgColor("OUTDOOR_AMBIENT_COLOR", 100, 100, 100))
    else
        restoreLightingProperty("OutdoorAmbient")
    end
end

-- strongest of the lighting overrides, applied last so it is not fought over
local function applyFullbright()
    if cfgBool("FULLBRIGHT") then
        setLighting("GlobalShadows", false)
        setLighting("Brightness", 2)
        setLighting("Ambient", Color3.new(1, 1, 1))
        return
    end

    restoreLightingProperty("GlobalShadows")
    restoreLightingProperty("Brightness")
    restoreLightingProperty("Ambient")
end

local function applyNoFog()
    if cfgBool("NO_FOG") then
        setLighting("FogStart", 0)
        setLighting("FogEnd", 100000)
        return
    end

    restoreLightingProperty("FogStart")
    restoreLightingProperty("FogEnd")
end

----------------------------------------------------------------------
-- map part material / texture stripping
----------------------------------------------------------------------

local function applyNoTextures()
    if cfgBool("NO_TEXTURES") then
        if appliedMap.Textures then return end
        appliedMap.Textures = true

        forEachMapPart(function(part)
            setPartProperty(part, "Material", Enum.Material.SmoothPlastic)
            setPartProperty(part, "TextureID", "")
        end)
        return
    end

    if not appliedMap.Textures then return end
    appliedMap.Textures = false

    restorePartProperty("Material")
    restorePartProperty("TextureID")
end

----------------------------------------------------------------------
-- terrain grass
----------------------------------------------------------------------

local function applyRemoveGrass()
    local terrain = nil
    pcall(function() terrain = Workspace:FindFirstChildOfClass("Terrain") end)
    if not terrain then return end

    local store = WorldMods.Cache

    if cfgBool("REMOVE_GRASS") then
        if store.TerrainDecoration == nil then
            pcall(function() store.TerrainDecoration = terrain.Decoration end)
        end

        pcall(function() terrain.Decoration = false end)
        return
    end

    if store.TerrainDecoration == nil then return end

    local original = store.TerrainDecoration
    pcall(function() terrain.Decoration = original end)
    store.TerrainDecoration = nil
end

----------------------------------------------------------------------
-- skybox
----------------------------------------------------------------------

local function applySkybox()
    if not cfgBool("SKYBOX_ENABLED") then
        destroyEffect("Sky")
        return
    end

    -- already created and still parented, nothing to do
    if getEffect("Sky", "Sky") == nil then return end

    local asset = cfgString("SKYBOX_ID", "rbxassetid://159454299")
    local sky = WorldMods.Effects.Sky

    pcall(function()
        sky.SkyboxUp = asset
        sky.SkyboxDn = asset
        sky.SkyboxLf = asset
        sky.SkyboxRt = asset
        sky.SkyboxFt = asset
        sky.SkyboxBk = asset
    end)
end

----------------------------------------------------------------------
-- map colour
----------------------------------------------------------------------

local function currentMapMode()
    local mode = cfgValue("MAP_COLOR_MODE")
    if type(mode) == "string" and VALID_MAP_MODES[mode] then return mode end
    return "Tint"
end

local function applyMapColorTint(enabled, color)
    if enabled then
        if appliedMap.Tint then return end
        appliedMap.Tint = true

        forEachMapPart(function(part)
            setPartProperty(part, "Color", color)
        end)
        return
    end

    if not appliedMap.Tint then return end
    appliedMap.Tint = false

    restorePartProperty("Color")
end

local function applyMapColorAmbient(enabled, color)
    if enabled then
        setLighting("Ambient", color)
        setLighting("OutdoorAmbient", color)
        return
    end

    restoreLightingProperty("Ambient")
    restoreLightingProperty("OutdoorAmbient")
end

local function applyMapColorSaturation(enabled)
    local saturation = clamp(cfgNumber("MAP_SATURATION", 0), -1, 1)

    applyEffect("MapColorCorrection", "ColorCorrectionEffect", enabled, function(effect)
        effect.Saturation = saturation
    end)
end

local function applyMapColor()
    local enabled = cfgBool("MAP_COLOR_ENABLED")
    local mode = currentMapMode()
    local color = cfgColor("MAP_COLOR", 255, 255, 255)

    local tint = enabled and (mode == "Tint" or mode == "Both")
    local ambient = enabled and (mode == "Ambient" or mode == "Both")
    local saturation = enabled and mode == "Saturation"

    applyMapColorTint(tint, color)
    applyMapColorAmbient(ambient, color)
    applyMapColorSaturation(saturation)
end

----------------------------------------------------------------------
-- post processing
----------------------------------------------------------------------

local function applyBloom()
    local enabled = cfgBool("BLOOM_ENABLED")
    local intensity = cfgNumber("BLOOM_INTENSITY", 1)
    local size = cfgNumber("BLOOM_SIZE", 24)
    local threshold = cfgNumber("BLOOM_THRESHOLD", 0.9)

    applyEffect("Bloom", "BloomEffect", enabled, function(effect)
        effect.Intensity = intensity
        effect.Size = size
        effect.Threshold = threshold
    end)
end

local function applyColorCorrection()
    local enabled = cfgBool("COLOR_CORRECTION_ENABLED")
    local brightnessValue = cfgNumber("CC_BRIGHTNESS", 0)
    local contrast = cfgNumber("CC_CONTRAST", 0)
    local saturation = cfgNumber("CC_SATURATION", 0)
    local tint = cfgColor("CC_TINT_COLOR", 255, 255, 255)

    applyEffect("ColorCorrection", "ColorCorrectionEffect", enabled, function(effect)
        effect.Brightness = brightnessValue
        effect.Contrast = contrast
        effect.Saturation = saturation
        effect.TintColor = tint
    end)
end

local function applySunRays()
    local enabled = cfgBool("SUN_RAYS_ENABLED")
    local intensity = cfgNumber("SUN_RAYS_INTENSITY", 0.25)
    local spread = cfgNumber("SUN_RAYS_SPREAD", 1)

    applyEffect("SunRays", "SunRaysEffect", enabled, function(effect)
        effect.Intensity = intensity
        effect.Spread = spread
    end)
end

local function applyMotionBlur()
    local enabled = cfgBool("MOTION_BLUR_ENABLED")
    local strength = cfgNumber("MOTION_BLUR_STRENGTH", 1)

    applyEffect("MotionBlur", "BlurEffect", enabled, function(effect)
        effect.Size = strength
    end)
end

----------------------------------------------------------------------
-- frame loop
----------------------------------------------------------------------

local function update()
    pcall(applyFov)

    pcall(applyClockTime)
    pcall(applyBrightness)
    pcall(applyAmbient)
    pcall(applyOutdoorAmbient)
    pcall(applyMapColor)
    pcall(applyFullbright)

    pcall(applyNoFog)
    pcall(applyNoTextures)
    pcall(applyRemoveGrass)
    pcall(applySkybox)

    pcall(applyBloom)
    pcall(applyColorCorrection)
    pcall(applySunRays)
    pcall(applyMotionBlur)
end

----------------------------------------------------------------------
-- public api
----------------------------------------------------------------------

function WorldMods.init(Config)
    if WorldMods.Initialized then return end
    WorldMods.Initialized = true

    storedConfig = Config

    WorldMods.Connection = RunService.RenderStepped:Connect(function()
        pcall(update)
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

    appliedMap.Textures = false
    appliedMap.Tint = false

    restoreAllParts()
    restoreAllLighting()

    if WorldMods.Cache.TerrainDecoration ~= nil then
        local original = WorldMods.Cache.TerrainDecoration
        pcall(function()
            local terrain = Workspace:FindFirstChildOfClass("Terrain")
            if terrain then terrain.Decoration = original end
        end)
        WorldMods.Cache.TerrainDecoration = nil
    end

    for name, effect in pairs(WorldMods.Effects) do
        pcall(function() effect:Destroy() end)
        WorldMods.Effects[name] = nil
    end

    storedConfig = nil
    WorldMods.Initialized = false
end

return WorldMods
