-- hit sound player
-- Plays a custom sound whenever one of our bullets registers a hit on an enemy.
-- Roblox can only play audio that exists as an asset, so local files are converted
-- with the executor's getcustomasset()/getsynasset() helpers. A manually entered
-- asset id always takes priority and is used when no local file can be resolved.

local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")

local HitSound = {
    Initialized = false,
    Sounds = {},
    PoolIndex = 0,
    PoolSize = 8,
    CurrentAsset = nil,
    Volume = 0.7,

    -- selectable sounds. 'file' is only used for locals that are converted with
    -- getcustomasset, everything else plays straight from its Roblox asset id.
    BUILTIN_SOUNDS = {
        { key = "hvh_crystal_hitsound.mp3", label = "Crystal hitsound",    file = "hvh_crystal_hitsound.mp3", defaultId = "115025250348704" },
        { key = "metal.wav",                label = "Metal hitsound",      file = "metal.wav",                defaultId = "140203855957422" },
        { key = "minecraft_bow_hit",        label = "Minecraft bow hit",                                      defaultId = "135478009117226" },
        { key = "tf2_critical",             label = "TF2 critical hit",                                       defaultId = "137392628136734" },
        { key = "undertale_critical",       label = "Undertale crit hit",                                     defaultId = "140181868959125" }
    },

    CUSTOM_VALUE = "Custom (asset ID)"
}

-- places searched for the audio file. The first entries are relative to the
-- executor workspace folder; the desktop location is included because that is
-- where the two bundled sounds are kept.
local searchDirs = {
    "Bloxstrike/hitsounds/",
    "Bloxstrike/",
    "hitsounds/",
    "hitsound.usethis/",
    "",
    "C:/Users/0909/Desktop/hitsound.usethis/",
    "C:\\Users\\0909\\Desktop\\hitsound.usethis\\"
}

-- Roblox refuses to play audio straight from an http url, so files hosted on the
-- repository are downloaded once into the workspace folder and converted locally.
local REMOTE_BASE = "https://raw.githubusercontent.com/alvin12127/roblox_bloxstrike_main/main/assets/"
local CACHE_DIR = "Bloxstrike/hitsounds/"
local downloadAttempted = {}

local function clamp01(n)
    if n < 0 then return 0 end
    if n > 1 then return 1 end
    return n
end

-- accepts either rbxassetid://<id>, a bare id or any already resolved content string
function HitSound.normalizeAsset(value)
    if type(value) ~= "string" then return nil end
    local trimmed = value:match("^%s*(.-)%s*$")
    if trimmed == "" then return nil end

    if trimmed:match("^rbxasset") then return trimmed end
    if trimmed:match("^%d+$") then return "rbxassetid://" .. trimmed end

    return trimmed
end

-- collect whatever local-file-to-asset converter the executor exposes
local function assetConverters()
    local converters = {}
    if type(getcustomasset) == "function" then table.insert(converters, getcustomasset) end
    if type(getsynasset) == "function" then table.insert(converters, getsynasset) end
    return converters
end

local function fileExists(path)
    if type(isfile) ~= "function" then return true end
    local ok, res = pcall(isfile, path)
    if not ok then return true end
    return res == true
end

-- pulls a hosted copy of the file down into the executor workspace
local function fetchFromRepository(fileName)
    if type(writefile) ~= "function" then return nil end
    if downloadAttempted[fileName] then return nil end
    downloadAttempted[fileName] = true

    local url = REMOTE_BASE .. fileName
    local body = nil

    -- these keep the raw bytes intact, game:HttpGet() often mangles binary data
    local requestApis = {}
    if type(syn) == "table" and type(syn.request) == "function" then table.insert(requestApis, syn.request) end
    if type(http_request) == "function" then table.insert(requestApis, http_request) end
    if type(http) == "table" and type(http.request) == "function" then table.insert(requestApis, http.request) end
    if type(request) == "function" then table.insert(requestApis, request) end

    for _, api in ipairs(requestApis) do
        local ok, res = pcall(api, { Url = url, Method = "GET" })
        if ok and type(res) == "table" and type(res.Body) == "string" and #res.Body > 0 then
            body = res.Body
            break
        end
    end

    if not body then
        local ok, res = pcall(function() return game:HttpGet(url) end)
        if ok and type(res) == "string" and #res > 0 then
            body = res
        end
    end

    if not body or #body < 512 then return nil end

    pcall(function()
        if type(makefolder) == "function" then
            if type(isfolder) == "function" then
                if not isfolder("Bloxstrike") then makefolder("Bloxstrike") end
                if not isfolder(CACHE_DIR) then makefolder(CACHE_DIR) end
            else
                pcall(makefolder, "Bloxstrike")
                pcall(makefolder, CACHE_DIR)
            end
        end
    end)

    local path = CACHE_DIR .. fileName
    local okWrite = pcall(writefile, path, body)
    if not okWrite then return nil end

    return path
end

local function resolveFile(fileName)
    if type(fileName) ~= "string" or fileName == "" then return nil end

    local converters = assetConverters()
    if #converters == 0 then return nil end

    local function tryResolve()
        for _, convert in ipairs(converters) do
            for _, dir in ipairs(searchDirs) do
                local path = dir .. fileName
                if fileExists(path) then
                    local ok, result = pcall(convert, path)
                    if ok and type(result) == "string" and #result > 0 then
                        return result
                    end
                end
            end
        end
        return nil
    end

    local localAsset = tryResolve()
    if localAsset then return localAsset end

    -- nothing on disk yet, grab it from the repository then convert
    local downloaded = fetchFromRepository(fileName)
    if downloaded then
        for _, convert in ipairs(converters) do
            local ok, result = pcall(convert, downloaded)
            if ok and type(result) == "string" and #result > 0 then
                return result
            end
        end
    end

    return nil
end

-- each sound can map to its own uploaded Roblox asset id
function HitSound.getAssetId(Config, key)
    local ids = Config.HITSOUND_IDS
    if type(ids) ~= "table" then return "" end
    return ids[key] or ""
end

function HitSound.setAssetId(Config, key, assetId)
    if type(Config.HITSOUND_IDS) ~= "table" then Config.HITSOUND_IDS = {} end
    Config.HITSOUND_IDS[key or ""] = tostring(assetId or "")
end

local function assetIdFor(Config, key)
    if type(Config.HITSOUND_IDS) ~= "table" or type(key) ~= "string" then return nil end
    return HitSound.normalizeAsset(Config.HITSOUND_IDS[key])
end

function HitSound.getLabels()
    local labels = {}
    for _, entry in ipairs(HitSound.BUILTIN_SOUNDS) do
        table.insert(labels, entry.label)
    end
    return labels
end

function HitSound.findEntry(key)
    if type(key) ~= "string" then return nil end
    for _, entry in ipairs(HitSound.BUILTIN_SOUNDS) do
        if entry.key == key then return entry end
    end
    return nil
end

function HitSound.getLabel(key)
    local entry = HitSound.findEntry(key)
    return entry and entry.label or nil
end

function HitSound.getKeyByLabel(label)
    if type(label) ~= "string" then return nil end
    for _, entry in ipairs(HitSound.BUILTIN_SOUNDS) do
        if entry.label == label then return entry.key end
    end
    return nil
end

-- seeds the built-in ids without overwriting ids the user edited themselves
function HitSound.ensureDefaults(Config)
    if type(Config.HITSOUND_IDS) ~= "table" then Config.HITSOUND_IDS = {} end
    for _, entry in ipairs(HitSound.BUILTIN_SOUNDS) do
        if entry.defaultId then
            local current = Config.HITSOUND_IDS[entry.key]
            if current == nil or current == "" then
                Config.HITSOUND_IDS[entry.key] = entry.defaultId
            end
        end
    end
end

function HitSound.resolveAsset(Config)
    local selected = Config.HITSOUND_FILE
    local named = (type(selected) == "string") and (selected ~= "") and (selected ~= HitSound.CUSTOM_VALUE)

    -- an uploaded Roblox id attached to the selected sound comes first
    if named then
        local own = assetIdFor(Config, selected)
        if own then return own end
    end

    -- generic override used by the custom entry
    local manual = HitSound.normalizeAsset(Config.HITSOUND_ASSET_ID)
    if manual then return manual end

    -- an explicitly picked file is used on its own so a missing selection never
    -- silently falls through to a different sound
    if named then
        local entry = HitSound.findEntry(selected)
        local fileName = (entry and entry.file) or selected
        return resolveFile(fileName)
    end

    -- no explicit selection: fall back to the first built-in id
    for _, entry in ipairs(HitSound.BUILTIN_SOUNDS) do
        if entry.defaultId then
            return HitSound.normalizeAsset(entry.defaultId)
        end
    end

    return nil
end

function HitSound.destroyPool()
    for _, sound in ipairs(HitSound.Sounds) do
        pcall(function() sound:Destroy() end)
    end
    HitSound.Sounds = {}
    HitSound.PoolIndex = 0
end

function HitSound.setVolume(level)
    HitSound.Volume = clamp01(tonumber(level) or 0.7)
    for _, sound in ipairs(HitSound.Sounds) do
        pcall(function() sound.Volume = HitSound.Volume end)
    end
end

-- (re)builds the rotating sound pool, returns ok + status message
function HitSound.build(Config)
    HitSound.destroyPool()

    local asset = HitSound.resolveAsset(Config)
    HitSound.CurrentAsset = asset

    if not asset then
        return false, "No usable audio source"
    end

    for i = 1, HitSound.PoolSize do
        local ok, sound = pcall(function()
            local s = Instance.new("Sound")
            s.Name = "BS_HitSound_" .. tostring(i)
            s.SoundId = asset
            s.Volume = HitSound.Volume
            s.RollOffMaxDistance = 100000
            s.Parent = SoundService
            return s
        end)
        if ok and sound then
            table.insert(HitSound.Sounds, sound)
        end
    end

    if #HitSound.Sounds == 0 then
        return false, "Failed to create sound instances"
    end

    pcall(function() ContentProvider:PreloadAsync(HitSound.Sounds) end)

    return true, nil
end

function HitSound.isReady()
    return #HitSound.Sounds > 0
end

function HitSound.play()
    if #HitSound.Sounds == 0 then return end

    HitSound.PoolIndex = (HitSound.PoolIndex % #HitSound.Sounds) + 1
    local sound = HitSound.Sounds[HitSound.PoolIndex]
    if not sound then return end

    pcall(function()
        sound.TimePosition = 0
        sound.Volume = HitSound.Volume
        sound:Play()
    end)
end

-- called on every confirmed hit, respects the master toggle
function HitSound.onHit(Config)
    if Config.HITSOUND_ENABLED ~= true then return end
    HitSound.play()
end

function HitSound.refresh(Config)
    HitSound.setVolume((tonumber(Config.HITSOUND_VOLUME) or 70) / 100)
    return HitSound.build(Config)
end

function HitSound.init(Config)
    if HitSound.Initialized then return end
    HitSound.Initialized = true
    HitSound.setVolume((tonumber(Config.HITSOUND_VOLUME) or 70) / 100)
    HitSound.ensureDefaults(Config)
    HitSound.build(Config)
end

function HitSound.cleanup()
    HitSound.destroyPool()
    HitSound.CurrentAsset = nil
    HitSound.Initialized = false
end

return HitSound
