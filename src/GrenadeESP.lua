-- grenade esp
-- Traces grenades anywhere in the workspace. Grenades are matched by name hints
-- because the game does not expose a type marker; Config.GRENADE_NAMES can be
-- used to add further names without touching this module.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Camera = Workspace.CurrentCamera

local GrenadeESP = {
    Initialized = false,
    Connection = nil
}

local storedConfig = nil

local HINTS = {
    "grenade", "granade", "flash", "smoke", "molotov",
    "incendiary", "cesar", "spike", "c4", "bomb"
}

local SCAN_INTERVAL = 0.25
local GRACE_MISSES = 2

local drawings = {}   -- [instance] = { Box, Text }
local missCount = {}  -- [instance] = how many consecutive scans missed it
local lastScan = 0

local function isGrenadeName(name)
    if type(name) ~= "string" then return false end
    local lower = name:lower()

    local hints = (storedConfig and type(storedConfig.GRENADE_NAMES) == "table") and storedConfig.GRENADE_NAMES or HINTS

    for _, hint in ipairs(hints) do
        if type(hint) == "string" and hint ~= "" and lower:find(hint, 1, true) then
            return true
        end
    end

    return false
end

local function getWorldPosition(inst)
    if inst:IsA("BasePart") then
        return inst.Position
    end

    local part = inst.PrimaryPart or inst:FindFirstChildOfClass("BasePart")
    return part and part.Position or nil
end

-- thrown or placed objects sit anywhere under the workspace; anything carried by
-- a player is filtered out through the characters folder
local function scanForGrenades()
    local charsFolder = Workspace:FindFirstChild("Characters")
    local seen = {}

    local function consider(inst)
        if (not inst) or seen[inst] then return end

        if not (inst:IsA("BasePart") or inst:IsA("Model")) then return end
        if charsFolder and inst:IsDescendantOf(charsFolder) then return end
        if not isGrenadeName(inst.Name) then return end

        seen[inst] = true
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

    return seen
end

local function ensureDrawings(inst)
    local set = drawings[inst]
    if set then return set end

    local okBox, box = pcall(function() return Drawing.new("Square") end)
    local okText, text = pcall(function() return Drawing.new("Text") end)

    if (not okBox) or (not box) or (not okText) or (not text) then
        if box then pcall(function() box:Remove() end) end
        if text then pcall(function() text:Remove() end) end
        return nil
    end

    box.Filled = false
    box.Thickness = 1.2
    box.Color = Color3.fromRGB(255, 190, 70)
    box.ZIndex = 4
    box.Visible = false

    text.Size = 12
    text.Center = true
    text.Color = Color3.fromRGB(255, 190, 70)
    text.Outline = false
    text.ZIndex = 5
    text.Visible = false

    set = { Box = box, Text = text }
    drawings[inst] = set
    missCount[inst] = 0

    return set
end

local function releaseDrawings(inst)
    local set = drawings[inst]
    if not set then return end

    pcall(function() set.Box:Remove() end)
    pcall(function() set.Text:Remove() end)

    drawings[inst] = nil
    missCount[inst] = nil
end

local function updateDrawings()
    local enabled = storedConfig and (storedConfig.GRENADE_ESP_ENABLED == true)

    for inst, set in pairs(drawings) do
        if not inst or inst.Parent == nil then
            releaseDrawings(inst)
        else
            local projected = nil

            if enabled then
                local position = getWorldPosition(inst)

                if position then
                    local ok, sp = pcall(Camera.WorldToViewportPoint, Camera, position)
                    if ok and sp and (sp.Z > 0.01) then
                        projected = sp
                    end
                end
            end

            if projected then
                local size = 26

                set.Box.Position = Vector2.new(projected.X - (size / 2), projected.Y - (size / 2))
                set.Box.Size = Vector2.new(size, size)
                set.Box.Visible = true

                set.Text.Text = inst.Name
                set.Text.Position = Vector2.new(projected.X, projected.Y - ((size / 2) + 3))
                set.Text.Visible = true
            else
                set.Box.Visible = false
                set.Text.Visible = false
            end
        end
    end
end

-- a single missed scan is tolerated so brief reparenting does not make the
-- drawings flicker
local function pruneUnmatched(seen)
    for inst in pairs(drawings) do
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

                local seen = scanForGrenades()
                pruneUnmatched(seen)

                for inst in pairs(seen) do
                    ensureDrawings(inst)
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

    for inst in pairs(drawings) do
        releaseDrawings(inst)
    end

    drawings = {}
    missCount = {}
    lastScan = 0
    storedConfig = nil
    GrenadeESP.Initialized = false
end

return GrenadeESP
