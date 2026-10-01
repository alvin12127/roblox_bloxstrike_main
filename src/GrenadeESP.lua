-- grenade and c4 esp
-- Ground truth from the game dump: every thrown grenade lives inside one of a
-- handful of containers that always sit a few levels under the workspace, so the
-- scan only walks those branches instead of the whole map:
--
--   [Folder] GrenadeParticles  ->  parts named "Smoke Grenade", "HE Grenade",
--                                  "Flashbang", "Molotov", "Decoy Grenade"
--   [Folder] VoxelSmoke_<id>   ->  the detonated smoke cloud (marker = folder)
--   [Folder] C4                ->  the planted / dropped bomb model
--
-- Two independent profiles with their own toggles and colors.

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

local CLOUD_PREFIX = "voxelsmoke"

local CONTAINER_HINTS = { "grenadeparticles", "voxelsmoke", "c4" }

local SCAN_INTERVAL = 0.25
local CONTAINER_SCAN_INTERVAL = 3
local FIND_DEPTH = 5
local GRACE_MISSES = 2
local PROXIMITY_THRESHOLD = 40

local entries = {}     -- [instance] = { Box, Text, category }
local missCount = {}   -- [instance] = consecutive scans without a match
local matchedNow = {}  -- rebuilt on every scan
local containers = {}  -- [container instance] = category, refreshed slowly
local lastScan = 0
local lastContainerScan = 0

-- exact name match only. Substring matching was what made dropped rifles and
-- unrelated props register as grenades.
-- needs to sit above matchCategory so the reference is a real upvalue and not
-- the global slot, which would be nil at runtime
local function resolveProfile(category)
    return PROFILES[category] or PROFILES.grenade
end

local function matchCategory(name)
    local lower = type(name) == "string" and name:lower() or ""

    if lower:sub(1, #CLOUD_PREFIX) == CLOUD_PREFIX then
        return "grenade"
    end

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

local function isCloudName(name)
    local lower = type(name) == "string" and name:lower() or ""
    return lower:sub(1, #CLOUD_PREFIX) == CLOUD_PREFIX
end

local function isContainerName(name)
    local lower = type(name) == "string" and name:lower() or ""

    for _, hint in ipairs(CONTAINER_HINTS) do
        if lower:find(hint, 1, true) then return true end
    end

    return false
end

local function containerCategory(containerName)
    local lower = type(containerName) == "string" and containerName:lower() or ""

    if lower:sub(1, #CLOUD_PREFIX) == CLOUD_PREFIX then
        return "grenade"
    end

    if lower:find("c4", 1, true) then
        return "c4"
    end

    return "grenade"
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

-- if a name matches both profiles, "c4" has to win or the marker would flicker
local function categorize(childName, fallback)
    local category = matchCategory(childName)
    return category or fallback
end

-- walk a container's contents and mark every object that belongs to its profile
local function collectFrom(container, containerCategory, depth)
    -- the smoke cloud is a folder with no position of its own, so the folder
    -- itself is the marker and its first base part supplies the coordinates
    if isCloudName(container.Name) then
        local position = getWorldPosition(container)
        if position and withinRange(position) then
            matchedNow = matchedNow or {}
            matchedNow[container] = "grenade"
        end
        return
    end

    for _, child in ipairs(container:GetChildren()) do
        if child:IsA("BasePart") or child:IsA("Model") then
            local position = getWorldPosition(child)

            if position and withinRange(position) then
                local category = categorize(child.Name, containerCategory)
                if not matchedNow then matchedNow = {} end
                matchedNow[child] = category
            end
        end

        -- one extra level so a model (like the C4 "Weapon" rig) exposes its parts
        if depth < 2 then
            collectFrom(child, containerCategory, depth + 1)
        end
    end
end

-- The dump shows the containers always live in fixed spots, so the scan only
-- looks there instead of walking the whole map:
--   Workspace.Assets.GrenadeParticles   (thrown grenades)
--   Workspace.Debris.VoxelSmoke_<id>    (smoke clouds - note: Debris, not Assets)
--   Workspace.Assets.Weapons.C4         (the bomb)
local ROOT_NAMES = { "Assets", "Debris" }

-- lookup of the container folders, refreshed on a slow timer
local function findContainers()
    local found = {}

    for _, rootName in ipairs(ROOT_NAMES) do
        local root = Workspace:FindFirstChild(rootName)
        if not root then root = game:FindFirstChild(rootName) end

        if root then
            for _, child in ipairs(root:GetChildren()) do
                if isContainerName(child.Name) then
                    found[child] = containerCategory(child.Name)
                elseif child:IsA("Folder") or child:IsA("Model") then
                    -- one more level, this is where Assets.Weapons.C4 sits
                    for _, grand in ipairs(child:GetChildren()) do
                        if isContainerName(grand.Name) then
                            found[grand] = containerCategory(grand.Name)
                        end
                    end
                end
            end
        end
    end

    return found
end

local function scanForObjects()
    local now = os.clock()

    if (now - lastContainerScan) >= CONTAINER_SCAN_INTERVAL then
        lastContainerScan = now
        containers = findContainers()
    end

    matchedNow = nil

    for container, category in pairs(containers) do
        if container and container.Parent ~= nil then
            collectFrom(container, category, 0)
        end
    end

    return matchedNow or {}
end

-- nested matches collapse to the outermost instance, and markers that sit right
-- on top of each other collapse too, so one smoke is always a single drawing
local function collapseMatches(matched)
    local outermost = {}
    for inst, category in pairs(matched) do
        local parent = inst.Parent
        local nested = false

        while parent and parent ~= Workspace do
            if matched[parent] then
                nested = true
                break
            end
            parent = parent.Parent
        end

        if not nested then
            outermost[inst] = category
        end
    end

    local keep = {}
    local taken = {}

    for inst, category in pairs(outermost) do
        if not taken[inst] then
            keep[inst] = category
            taken[inst] = true

            local position = getWorldPosition(inst)

            for other, otherCategory in pairs(outermost) do
                if (not taken[other]) and (otherCategory == category) then
                    local otherPosition = getWorldPosition(other)

                    if position and otherPosition and
                        (otherPosition - position).Magnitude <= PROXIMITY_THRESHOLD then
                        taken[other] = true
                    end
                end
            end
        end
    end

    return keep
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
                pcall(function() set.Box.Visible = false end)
                pcall(function() set.Text.Visible = false end)
            end
        end
    end
end

-- one missed scan is tolerated, so a brief reparenting cannot cause flicker
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

                local seen = collapseMatches(scanForObjects())
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
    matchedNow = {}
    containers = {}
    lastScan = 0
    lastContainerScan = 0
    storedConfig = nil
    GrenadeESP.Initialized = false
end

return GrenadeESP
