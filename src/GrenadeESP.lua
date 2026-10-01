-- grenade and c4 esp
-- Name driven, and deliberately simple: the game dump told us exactly what these
-- objects are called, so matching is a plain name lookup.
--
--   grenades  : "Smoke Grenade", "HE Grenade", "Flashbang", "Molotov",
--               "Decoy Grenade", "Incendiary Grenade"   (thrown, live in
--               Workspace.Assets.GrenadeParticles)
--   smoke     : "VoxelSmoke_<id>" folders              (live in Workspace.Debris)
--   c4        : "C4"                                   (Workspace.Assets.Weapons)
--
-- Everything else is invisible to this module, which is why dropped rifles never
-- show up. Two profiles, each own toggle and color.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local GrenadeESP = {
    Initialized = false,
    Connection = nil
}

local storedConfig = nil

-- straight from the dump. "grenadetrail" is the object that exists while a
-- grenade is still in the air, the named parts only show up once it goes off.
local GRENADE_NAMES = {
    "smoke grenade", "he grenade", "incendiary grenade", "decoy grenade",
    "flashbang", "molotov", "grenadetrail", "grenade"
}

local C4_NAMES = { "c4" }

local CLOUD_PREFIX = "voxelsmoke"

-- where these objects live, with a per-root depth budget. Scanning only these
-- branches is what keeps the cost near zero on large maps.
local SEARCH_ROOTS = {
    { name = "Assets",    depth = 4 },
    { name = "Debris",    depth = 3 },
    { name = "Workspace", depth = 3 }
}

local SCAN_INTERVAL = 0.25
local GRACE_MISSES = 2
-- Only meant to merge two markers of the *same* object, e.g. the grenade and the
-- cloud it leaves behind. The dump shows the parked grenade parts sitting 1-35
-- studs apart, so a large radius here silently ate Molotov and Decoy.
local PROXIMITY_THRESHOLD = 5

local PROFILE_GRENADE = "grenade"
local PROFILE_C4 = "c4"

local entries = {}     -- [instance] = { Box, Text, category }
local missCount = {}
local matchedNow = {}
local lastScan = 0

local diagnosticsLogged = 0
local lastSignature = nil

local function profileColor(category)
    return (category == PROFILE_C4) and Color3.fromRGB(255, 70, 70) or Color3.fromRGB(255, 190, 70)
end

local function profileEnabled(category)
    if not storedConfig then return false end

    if category == PROFILE_C4 then
        return storedConfig.C4_ESP_ENABLED == true
    end

    return storedConfig.GRENADE_ESP_ENABLED == true
end

local function namesFor(category)
    if category == PROFILE_C4 then return C4_NAMES end

    if storedConfig and type(storedConfig.GRENADE_NAMES) == "table"
        and #storedConfig.GRENADE_NAMES > 0 then
        return storedConfig.GRENADE_NAMES
    end

    return GRENADE_NAMES
end

local function isCloud(name)
    local lower = type(name) == "string" and name:lower() or ""
    return lower:sub(1, #CLOUD_PREFIX) == CLOUD_PREFIX
end

-- "c4" is checked first so a name matching both profiles cannot flicker
local function categoryFor(name)
    local lower = type(name) == "string" and name:lower() or ""

    if isCloud(name) then
        return PROFILE_GRENADE
    end

    local order = { PROFILE_C4, PROFILE_GRENADE }

    for _, category in ipairs(order) do
        for _, candidate in ipairs(namesFor(category)) do
            if lower == tostring(candidate):lower() then
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

-- The dump pinned down where these objects live, so membership is decided by the
-- container instead of by guessing at names. GrenadeParticles holds exactly the
-- live grenade parts, and only the two fire effect parts are filtered out.
local EFFECT_EXCLUDE = { outerfire = true, innerfire = true }

-- folders and models only; map geometry is made of parts, so this stays cheap
local function scanForObjects()
    matchedNow = {}

    local function mark(inst, category, position)
        if position and withinRange(position) then
            matchedNow[inst] = category
        end
    end

    -- everything directly under GrenadeParticles is a live grenade
    local function collectGrenades(folder)
        for _, child in ipairs(folder:GetChildren()) do
            if child:IsA("BasePart") then
                local lower = child.Name:lower()

                if not EFFECT_EXCLUDE[lower] then
                    mark(child, PROFILE_GRENADE, getWorldPosition(child))
                end
            end
        end
    end

    -- remaining is the number of levels left to descend; each level's children
    -- are name checked before deciding whether to go deeper
    local function walk(inst, remaining)
        if (not inst) or remaining <= 0 then return end

        for _, child in ipairs(inst:GetChildren()) do
            local lower = child.Name:lower()

            if lower == "grenadeparticles" then
                collectGrenades(child)

            elseif lower:sub(1, #CLOUD_PREFIX) == CLOUD_PREFIX then
                -- the cloud is a folder of voxel parts, so the folder is the marker
                mark(child, PROFILE_GRENADE, getWorldPosition(child))

            elseif lower == "c4" and (child:IsA("Folder") or child:IsA("Model")) then
                -- Assets.Weapons.C4 holds the bomb rig. The skin and animation
                -- folders sharing that name hold no parts and cannot produce a
                -- position, so they are filtered out by mark() automatically.
                mark(child, PROFILE_C4, getWorldPosition(child))

            else
                local category = categoryFor(child.Name)

                if category then
                    mark(child, category, getWorldPosition(child))
                    walk(child, remaining - 1)
                elseif child:IsA("Folder") or child:IsA("Model") then
                    walk(child, remaining - 1)
                end
            end
        end
    end

    for _, rootSpec in ipairs(SEARCH_ROOTS) do
        local root = (rootSpec.name == "Workspace") and Workspace or Workspace:FindFirstChild(rootSpec.name)
        if not root then root = game:FindFirstChild(rootSpec.name) end

        if root then
            walk(root, rootSpec.depth)
        end
    end

    return matchedNow
end

-- markers that sit on top of each other are collapsed, so one smoke is always
-- drawn once even though both the grenade and its cloud are present
local function collapseMatches(matched)
    local keep = {}
    local taken = {}

    for inst, category in pairs(matched) do
        if not taken[inst] then
            keep[inst] = category
            taken[inst] = true

            local position = getWorldPosition(inst)

            for other, otherCategory in pairs(matched) do
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
            local enabled = profileEnabled(set.category)
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
                local color = profileColor(set.category)

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

-- a single missed scan is tolerated so brief reparenting cannot cause flicker
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

local function reportMatches(matched)
    local names = {}

    for inst, category in pairs(matched) do
        table.insert(names, inst.Name .. "[" .. category .. "]")
    end
    table.sort(names)

    local signature = table.concat(names, " | ")

    if signature ~= lastSignature then
        lastSignature = signature
        diagnosticsLogged = diagnosticsLogged + 1

        if diagnosticsLogged <= 4 then
            if signature == "" then
                pcall(warn, "[Bloxstrike] grenade esp: nothing matched")
            else
                pcall(warn, "[Bloxstrike] grenade esp matches: " .. signature)
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
        -- scanning is throttled, but the drawings themselves are refreshed every
        -- frame so the markers do not stutter
        pcall(function()
            local now = os.clock()

            if (now - lastScan) >= SCAN_INTERVAL then
                lastScan = now

                local seen = collapseMatches(scanForObjects())
                reportMatches(seen)
                pruneUnmatched(seen)

                for inst, category in pairs(seen) do
                    ensureDrawings(inst, category)
                end
            end
        end)

        pcall(updateDrawings)
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
    lastScan = 0
    diagnosticsLogged = 0
    lastSignature = nil
    storedConfig = nil
    GrenadeESP.Initialized = false
end

return GrenadeESP
