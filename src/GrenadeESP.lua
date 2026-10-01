-- grenade and c4 esp
-- Ground truth from the game dump: thrown grenades are Parts/Models that carry
-- the exact inventory weapon name ("Smoke Grenade", "HE Grenade", "Flashbang",
-- "Molotov", "Incendiary Grenade", "Decoy Grenade") and the detonating smoke
-- cloud is a Folder whose name starts with "VoxelSmoke". Matching is exact on
-- purpose, which is why dropped rifles on the ground are never picked up.
--
-- Two independent profiles with their own toggles and colors: grenade and c4.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local GrenadeESP = {
    Initialized = false,
    Connection = nil
}

local storedConfig = nil

local PROFILES = {
    grenade = {
        configKey = "GRENADE_ESP_ENABLED",
        color = Color3.fromRGB(255, 190, 70),
        names = {
            "smoke grenade", "he grenade", "incendiary grenade", "decoy grenade",
            "flashbang", "molotov", "smokegrenade", "hegrenade", "incendiarygrenade",
            "decoygrenade"
        }
    },
    c4 = {
        configKey = "C4_ESP_ENABLED",
        color = Color3.fromRGB(255, 70, 70),
        names = { "c4", "bomb" }
    }
}

-- the smoke cloud carries an extra marker neither profile covers exactly
local CLOUD_PREFIX = "voxelsmoke"

local SCAN_INTERVAL = 0.25
local MAX_DEPTH = 5
local GRACE_MISSES = 2

local entries = {}     -- [instance] = { Box, Text, category }
local missCount = {}   -- [instance] = consecutive scans without a match
local lastScan = 0

local function resolveProfile(category)
    return PROFILES[category] or PROFILES.grenade
end

local function isCloudName(name)
    return type(name) == "string" and name:lower():sub(1, #CLOUD_PREFIX) == CLOUD_PREFIX
end

local function matchCategory(name)
    local lower = type(name) == "string" and name:lower() or ""

    if isCloudName(name) then
        return "grenade"
    end

    -- "c4" first so a name that could belong to both profiles stays stable
    local order = { "c4", "grenade" }

    for _, category in ipairs(order) do
        for _, candidate in ipairs(resolveProfile(category).names) do
            if lower == candidate then
                return category
            end
        end
    end

    return nil
end

local function getWorldPosition(inst)
    if inst:IsA("BasePart") then
        return inst.Position
    end

    local part = inst.PrimaryPart or inst:FindFirstChildOfClass("BasePart")
    return part and part.Position or nil
end

local function withinRange(position)
    local camera = Workspace.CurrentCamera
    if not camera then return false end

    local limit = tonumber(storedConfig and storedConfig.GRENADE_ESP_MAX_DIST) or 300
    return (position - camera.CFrame.Position).Magnitude <= limit
end

local function hasMatchedAncestor(inst, seen)
    local parent = inst.Parent

    while parent and parent ~= Workspace do
        if seen[parent] then return true end
        parent = parent.Parent
    end

    return false
end

-- depth limited traversal: grenades only live a few levels under the workspace
-- and a full descendants() walk is far too costly on large maps
local function scanForObjects()
    local charsFolder = Workspace:FindFirstChild("Characters")
    local matched = {}

    local function walk(inst, depth)
        if depth > MAX_DEPTH then return end
        if not inst then return end

        for _, child in ipairs(inst:GetChildren()) do
            if child ~= charsFolder then
                -- Carried gear lives inside a character, so cut that branch off
                if not (charsFolder and child:IsDescendantOf(charsFolder)) then
                    local category = matchCategory(child.Name)

                    if category then
                        local position = getWorldPosition(child)
                        if position and withinRange(position) then
                            matched[child] = category
                        end
                    end

                    walk(child, depth + 1)
                end
            end
        end
    end

    walk(Workspace, 0)

    -- collapse nested matches so a single smoke never shows up twice
    local collapsed = {}
    for inst, category in pairs(matched) do
        if not hasMatchedAncestor(inst, matched) then
            collapsed[inst] = category
        end
    end

    return collapsed
end

local function ensureDrawings(inst, category)
    local set = entries[inst]
    if set then
        set.category = category
        return set
    end

    local okBox, box = pcall(function() return Drawing.new("Square") end)
    local okText, text = pcall(function() return Drawing.new("Text") end)

    if (not okBox) or (not box) or (not okText) or (not text) then
        if box then pcall(function() box:Remove() end) end
        if text then pcall(function() text:Remove() end) end
        return nil
    end

    box.Filled = false
    box.Thickness = 1.2
    box.ZIndex = 4
    box.Visible = false

    text.Size = 12
    text.Center = true
    text.Outline = false
    text.ZIndex = 5
    text.Visible = false

    set = { Box = box, Text = text, category = category }
    entries[inst] = set
    missCount[inst] = 0

    return set
end

local function releaseDrawings(inst)
    local set = entries[inst]
    if not set then return end

    pcall(function() set.Box:Remove() end)
    pcall(function() set.Text:Remove() end)

    entries[inst] = nil
    missCount[inst] = nil
end

local function setEnabled(set, on)
    if set then
        pcall(function() set.Box.Visible = on end)
        pcall(function() set.Text.Visible = on end)
    end
end

local function updateDrawings()
    local camera = Workspace.CurrentCamera
    if not camera then return end

    for inst, set in pairs(entries) do
        if (not inst) or inst.Parent == nil then
            releaseDrawings(inst)
        else
            local profile = resolveProfile(set.category)
            local enabled = storedConfig and storedConfig[profile.configKey] == true
            local projected = nil

            if enabled then
                local position = getWorldPosition(inst)

                if position then
                    local ok, sp = pcall(camera.WorldToViewportPoint, camera, position)
                    if ok and sp and (sp.Z > 0.01) then
                        projected = sp
                    end
                end
            end

            if projected then
                local size = 26
                local color = profile.color

                pcall(function()
                    set.Box.Position = Vector2.new(projected.X - (size / 2), projected.Y - (size / 2))
                    set.Box.Size = Vector2.new(size, size)
                    set.Box.Color = color
                    set.Box.Visible = true
                end)

                pcall(function()
                    set.Text.Text = inst.Name
                    set.Text.Position = Vector2.new(projected.X, projected.Y - ((size / 2) + 3))
                    set.Text.Color = color
                    set.Text.Visible = true
                end)
            else
                setEnabled(set, false)
            end
        end
    end
end

-- one missed scan is tolerated so brief reparenting cannot cause flicker
local function pruneUnmatched(seen)
    for inst in pairs(entries) do
        if seen[inst] then
            missCount[inst] = 0
        else
            local misses = (missCount[inst] or 0) + 1
            missCount[inst] = misses

            if misses >= GRACE_MISSES then
                releaseDrawings(inst)
            end
        end
    end
end

function GrenadeESP.init(Config)
    if GrenadeESP.Initialized then return end
    GrenadeESP.Initialized = true

    storedConfig = Config
    lastScan = 0

    GrenadeESP.Connection = RunService.RenderStepped:Connect(function()
        pcall(function()
            local now = os.clock()

            if (now - lastScan) >= SCAN_INTERVAL then
                lastScan = now

                local seen = scanForObjects()
                pruneUnmatched(seen)

                for inst, category in pairs(seen) do
                    ensureDrawings(inst, category)
                end
            end

            updateDrawings()
        end)
    end)
end

function GrenadeESP.cleanup()
    if GrenadeESP.Connection then
        pcall(function() GrenadeESP.Connection:Disconnect() end)
        GrenadeESP.Connection = nil
    end

    for inst in pairs(entries) do
        releaseDrawings(inst)
    end

    entries = {}
    missCount = {}
    lastScan = 0
    storedConfig = nil
    GrenadeESP.Initialized = false
end

return GrenadeESP
