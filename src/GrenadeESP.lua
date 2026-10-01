-- grenade and c4 esp
-- Thrown objects are matched purely by name hints because the game does not
-- mark them. Two independent profiles are maintained: "grenade" and "c4", each
-- own toggle and color. Anything carried by a player is skipped, nested matches
-- (a model plus its parts) are collapsed to the outermost instance, and matches
-- are limited to a radius so static map props far away stay out of the way.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local GrenadeESP = {
    Initialized = false,
    Connection = nil
}

local storedConfig = nil

local PROFILES = {
    grenade = {
        hints = { "grenade", "granade", "flash", "smoke", "molotov", "incendiary", "cesar", "spike" },
        color = Color3.fromRGB(255, 190, 70),
        configKey = "GRENADE_ESP_ENABLED"
    },
    c4 = {
        hints = { "c4", "bomb", "explosive", "planted", "defuse" },
        color = Color3.fromRGB(255, 70, 70),
        configKey = "C4_ESP_ENABLED"
    }
}

local SCAN_INTERVAL = 0.25
local GRACE_MISSES = 2

local entries = {}     -- [instance] = { Box, Text, category }
local missCount = {}   -- [instance] = consecutive scans without a match
local lastScan = 0

local function hintsFor(category)
    local fromConfig = storedConfig and storedConfig.GRENADE_NAMES

    if type(fromConfig) ~= "table" or #fromConfig == 0 then
        return PROFILES[category].hints
    end

    -- Config.GRENADE_NAMES applies to the grenade profile only
    if category == "grenade" then
        return fromConfig
    end

    return PROFILES[category].hints
end

local function matchCategory(name)
    if type(name) ~= "string" then return nil end
    local lower = name:lower()

    -- pairs() is unordered, so c4 is checked first on purpose to keep a name
    -- that matches both profiles from flickering between categories
    local order = { "c4", "grenade" }

    for _, category in ipairs(order) do
        for _, hint in ipairs(hintsFor(category)) do
            if type(hint) == "string" and hint ~= "" and lower:find(hint, 1, true) then
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

-- anything nested under an instance that already matched is collapsed, which is
-- what stops a single smoke from showing up as several drawings at once
local function hasMatchedAncestor(inst, seen)
    local parent = inst.Parent

    while parent and parent ~= Workspace do
        if seen[parent] then return true end
        parent = parent.Parent
    end

    return false
end

local function scanForObjects()
    local charsFolder = Workspace:FindFirstChild("Characters")
    local matched = {}

    local function consider(inst)
        if (not inst) or matched[inst] then return end
        if not (inst:IsA("BasePart") or inst:IsA("Model")) then return end
        if charsFolder and inst:IsDescendantOf(charsFolder) then return end

        local category = matchCategory(inst.Name)
        if not category then return end

        local position = getWorldPosition(inst)
        if not position or not withinRange(position) then return end

        matched[inst] = category
    end

    for _, child in ipairs(Workspace:GetChildren()) do
        if child ~= charsFolder then
            consider(child)

            for _, sub in ipairs(child:GetChildren()) do
                consider(sub)

                for _, leaf in ipairs(sub:GetChildren()) do
                    consider(leaf)
                end
            end
        end
    end

    -- collapse nested matches
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
            local profile = PROFILES[set.category] or PROFILES.grenade
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

-- a single missed scan is tolerated so brief reparenting cannot make the
-- drawings flicker
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
