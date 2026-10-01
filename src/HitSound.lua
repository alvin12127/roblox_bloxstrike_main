-- hit sound player
-- Plays a custom sound whenever one of our bullets registers a hit on an enemy.
-- Roblox can only play audio that exists as an asset, so local files are converted
-- with the executor's getcustomasset()/getsynasset() helpers. A manually entered
-- asset id always takes priority and is used when no local file can be resolved.

local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local LocalPlayer = Players.LocalPlayer

local HitSound = {
    Initialized = false,
    Sounds = {},
    PoolIndex = 0,
    PoolSize = 8,
    CurrentAsset = nil,
    Volume = 0.7,
    LastPlayed = {},

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

        local asset = resolveFile(fileName)
        if asset then return asset end

        -- fall back to the first built-in id before giving up entirely
        for _, candidate in ipairs(HitSound.BUILTIN_SOUNDS) do
            if candidate.defaultId then
                local fallback = HitSound.normalizeAsset(candidate.defaultId)
                if fallback then return fallback end
            end
        end

        return nil
    end

    -- no explicit selection: the first built-in id is a safe default
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
-- Builds the pool without ever leaving it empty: the new instances are created
-- first and the old ones are only discarded once creation succeeded.

-- checks whether an asset can actually be loaded right now. Fresh uploads sit
-- in "Asset has not been reviewed" until Roblox moderates them and ids that no
-- longer exist answer "not found"; both mean we must not use that source.
-- A sound whose id never took effect still reports as "rbxassetid://0", and
-- preloading that spams the console with "Request asset was not found". So the
-- probe is only allowed to continue once the id really stuck.
local function probeAsset(assetId)
    local okSound, probe = pcall(Instance.new, "Sound")
    if (not okSound) or (not probe) then return false end

    local okSet = pcall(function() probe.SoundId = assetId end)
    if (not okSet) then
        pcall(function() probe:Destroy() end)
        return false
    end

    local applied = tostring(probe.SoundId or "")

    if applied == "" or applied:match("^rbxassetid://0+$") then
        pcall(function() probe:Destroy() end)
        return false
    end

    pcall(function()
        probe.Volume = 0
        probe.Parent = SoundService
    end)

    -- typeof() is required here: type() reports Roblox enum values as their raw
    -- kind, never as "EnumItem"
    local status = nil
    pcall(function()
        ContentProvider:PreloadAsync({ probe }, function(_assetId, fetchStatus)
            status = fetchStatus
        end)
    end)

    pcall(function() probe:Destroy() end)

    if typeof(status) ~= "EnumItem" then return false end
    return status == Enum.AssetFetchStatus.Success
end

-- cached so a refresh loop cannot keep re-probing the same rejected ids
local probeCache = {}
local PROBE_TTL = 60

local function isPlayable(assetId)
    if type(assetId) ~= "string" or assetId == "" then return false end

    local cached = probeCache[assetId]

    if cached and ((os.clock() - cached.at) < PROBE_TTL) then
        return cached.ok
    end

    local ok = probeAsset(assetId)
    probeCache[assetId] = { ok = ok, at = os.clock() }

    return ok
end

-- ordered by priority: the picked sound first, then everything else that might
-- still work, so a sound stuck in moderation never leaves the user mute
function HitSound.assetCandidates(Config)
    local candidates = {}

    local function add(asset)
        if type(asset) == "string" and asset ~= "" then
            table.insert(candidates, asset)
        end
    end

    local selected = Config.HITSOUND_FILE
    local named = (type(selected) == "string") and (selected ~= "") and (selected ~= HitSound.CUSTOM_VALUE)

    if named then
        add(assetIdFor(Config, selected))
        local entry = HitSound.findEntry(selected)
        if entry and entry.defaultId then
            add(HitSound.normalizeAsset(entry.defaultId))
        end
        add(resolveFile((entry and entry.file) or selected))
    end

    add(HitSound.normalizeAsset(Config.HITSOUND_ASSET_ID))

    -- every other built-in id, then any local file still lying around
    for _, entry in ipairs(HitSound.BUILTIN_SOUNDS) do
        if entry.defaultId and entry.key ~= selected then
            add(HitSound.normalizeAsset(entry.defaultId))
        end
    end

    for _, entry in ipairs(HitSound.BUILTIN_SOUNDS) do
        if entry.file then
            add(resolveFile(entry.file))
        end
    end

    return candidates
end

function HitSound.build(Config)
    local asset = nil

    for _, candidate in ipairs(HitSound.assetCandidates(Config)) do
        if isPlayable(candidate) then
            asset = candidate
            break
        end
    end

    HitSound.CurrentAsset = asset

    if not asset then
        return false, "No playable audio source"
    end

    local created = {}

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
            table.insert(created, sound)
        end
    end

    if #created == 0 then
        return false, "Failed to create sound instances"
    end

    HitSound.destroyPool()
    HitSound.Sounds = created

    pcall(function() ContentProvider:PreloadAsync(HitSound.Sounds) end)

    return true, nil
end

function HitSound.isReady()
    return #HitSound.Sounds > 0
end

-- `source` is optional and only used to suppress a duplicate trigger for the
-- same character (the raycast hit and the damage confirmation both fire)
function HitSound.play(source)
    if #HitSound.Sounds == 0 then return end

    local now = os.clock()
    if source then
        local previous = HitSound.LastPlayed[source]
        if previous and (now - previous) < 0.1 then return end
        HitSound.LastPlayed[source] = now
    end

    HitSound.PoolIndex = (HitSound.PoolIndex % #HitSound.Sounds) + 1
    local sound = HitSound.Sounds[HitSound.PoolIndex]
    if not sound then return end

    pcall(function()
        sound.TimePosition = 0
        sound.Volume = HitSound.Volume
        sound:Play()
    end)
end

----------------------------------------------------------------------
-- damage confirmation
--
-- Wallbang never shows up in the raycast result because it rewrites the
-- network packet instead, so wall hits can only be confirmed through health
-- loss. To make sure we never react to somebody else's damage, a health drop
-- only counts when it lands on the character we were aiming at, within a short
-- window after one of our own shots.
----------------------------------------------------------------------

local DAMAGE_WINDOW = 0.35      -- max delay between our shot and the health drop
local UNLOCKED_WINDOW = 0.12    -- tighter when we had no locked target

local Utils = nil
local storedConfig = nil
local lastShot = nil            -- { time = os.clock(), char = <model> }
local lastHealth = {}           -- model -> last known health
local watching = {}             -- model -> true
local damageConnections = {}

-- called every time one of our bullets is fired
function HitSound.setShot(targetChar)
    lastShot = { time = os.clock(), char = targetChar }
end

local function isEnemyCharacter(char)
    if not char or not char.Parent then return false end
    if char.Name == LocalPlayer.Name then return false end
    if char:GetAttribute("Dead") == true then return false end

    if Utils and Utils.isEnemy then
        local player = Players:FindFirstChild(char.Name)
        local ok, isEnemy = pcall(Utils.isEnemy, player, char)
        if ok and isEnemy == false then
            return false
        end
    end

    return true
end

-- only damage we caused may trigger a sound
local function isOurDamage(char)
    if not lastShot then return false end

    local elapsed = os.clock() - lastShot.time
    if elapsed > DAMAGE_WINDOW then return false end

    if lastShot.char then
        return char == lastShot.char
    end

    -- no locked target: accept only a very recent drop
    return elapsed <= UNLOCKED_WINDOW
end

local function evaluateHealth(char)
    if not storedConfig or storedConfig.HITSOUND_ENABLED ~= true then return end
    if not Utils or not Utils.getCharacterHealth then return end
    if not isEnemyCharacter(char) then
        lastHealth[char] = Utils.getCharacterHealth(char)
        return
    end

    local hp = Utils.getCharacterHealth(char)
    if type(hp) ~= "number" then return end

    local previous = lastHealth[char]
    lastHealth[char] = hp

    -- first sighting or healing, not damage
    if previous == nil or hp >= previous then return end

    if not isOurDamage(char) then return end

    HitSound.play(char)
end

local function watchCharacter(char)
    if watching[char] then return end
    watching[char] = true

    pcall(function()
        local signal = char:GetAttributeChangedSignal("Health")
        table.insert(damageConnections, signal:Connect(function()
            pcall(evaluateHealth, char)
        end))
    end)

    local humanoid = char:FindFirstChildOfClass("Humanoid")
    if humanoid then
        table.insert(damageConnections, humanoid.HealthChanged:Connect(function()
            pcall(evaluateHealth, char)
        end))
    end
end

function HitSound.startDamageWatch()
    local charsFolder = Workspace:FindFirstChild("Characters")
    if not charsFolder then return end

    for _, child in ipairs(charsFolder:GetChildren()) do
        if child:IsA("Model") then
            lastHealth[child] = (Utils and Utils.getCharacterHealth(child)) or nil
            watchCharacter(child)
        end
    end

    table.insert(damageConnections, charsFolder.ChildAdded:Connect(function(child)
        if child:IsA("Model") then
            lastHealth[child] = (Utils and Utils.getCharacterHealth(child)) or nil
            watchCharacter(child)
        end
    end))

    table.insert(damageConnections, charsFolder.ChildRemoved:Connect(function(child)
        watching[child] = nil
        lastHealth[child] = nil
    end))
end

function HitSound.stopDamageWatch()
    for _, connection in ipairs(damageConnections) do
        pcall(function() connection:Disconnect() end)
    end
    damageConnections = {}
    watching = {}
    lastHealth = {}
    lastShot = nil
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

function HitSound.init(Config, UtilsModule)
    if HitSound.Initialized then return end
    HitSound.Initialized = true

    storedConfig = Config
    Utils = UtilsModule

    HitSound.setVolume((tonumber(Config.HITSOUND_VOLUME) or 70) / 100)
    HitSound.ensureDefaults(Config)
    HitSound.build(Config)
    HitSound.startDamageWatch()
end

function HitSound.cleanup()
    HitSound.stopDamageWatch()
    HitSound.destroyPool()
    HitSound.LastPlayed = {}
    HitSound.CurrentAsset = nil
    HitSound.Initialized = false
    storedConfig = nil
    Utils = nil
end

return HitSound
