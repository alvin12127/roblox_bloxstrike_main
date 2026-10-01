-- c4 esp
-- Dedicated bomb tracker, kept completely separate from the grenade code.
--
-- Ground truth from the game dump:
--   * the player carrying the bomb has a "BombHolster" model parented to their
--     character (exactly one exists at a time, same as in CS)
--   * planted / dropped state comes from the local player's own attributes, the
--     same values the reference source reads for its bomb timer block.
--
-- What is drawn:
--   * "C4 Carrier" above whoever is holding the bomb
--   * a box plus a label on the physical bomb when it is on the ground, and the
--     remaining timer when it is planted.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local C4ESP = {
    Initialized = false,
    Connection = nil,
    Items = {}          -- [key] = { Box, Label }
}

local storedConfig = nil

local function getCamera()
    return Workspace.CurrentCamera
end

local function makeItem(key)
    local item = C4ESP.Items[key]

    if item then return item end

    local okBox, box = pcall(function() return Drawing.new("Square") end)
    local okText, label = pcall(function() return Drawing.new("Text") end)

    if (not okBox) or (not okText) then
        if okBox then pcall(function() box:Remove() end) end
        if okText then pcall(function() label:Remove() end) end
        return nil
    end

    pcall(function()
        box.Thickness = 1.5
        box.Filled = false
        box.Visible = false

        label.Size = 13
        label.Center = true
        label.Outline = true
        label.Visible = false
    end)

    item = { Box = box, Label = label }
    C4ESP.Items[key] = item

    return item
end

local function hideAll()
    for _, item in pairs(C4ESP.Items) do
        pcall(function()
            item.Box.Visible = false
            item.Label.Visible = false
        end)
    end
end

-- the bomb carrier is the only character with a BombHolster child
-- Also check for "Bomb" attribute as fallback
local function findBombCarrier()
    local characters = Workspace:FindFirstChild("Characters")
    if not characters then return nil end

    for _, character in ipairs(characters:GetChildren()) do
        -- Check for BombHolster child (primary method)
        if character:FindFirstChild("BombHolster") then
            return character
        end
        
        -- Check for Bomb attribute (fallback)
        local hasBomb = false
        pcall(function()
            hasBomb = (character:GetAttribute("HasBomb") == true) or (character:GetAttribute("Bomb") == true)
        end)
        if hasBomb then
            return character
        end
        
        -- Check player attributes
        local player = Players:FindFirstChild(character.Name)
        if player then
            local playerHasBomb = false
            pcall(function()
                playerHasBomb = (player:GetAttribute("HasBomb") == true) or (player:GetAttribute("Bomb") == true)
            end)
            if playerHasBomb then
                return character
            end
        end
    end

    return nil
end

local function isBombName(name)
    if type(name) ~= "string" then return false end

    if name == "C4" then return true end

    if name:lower():find("bomb", 1, true) then return true end

    return false
end

-- the physical bomb, anything outside the characters folder
-- From dump: C4 folder exists in Workspace, and BombHolster is a Model parented to character
-- Cached C4 folder list. Map layout does not change mid-round, so this is
-- resolved once and refreshed rarely instead of walking the Workspace tree
-- on every scan.
local c4FolderCache = nil
local c4FolderCacheTime = 0
local C4_FOLDER_TTL = 10

local function getC4Folders()
    local now = os.clock()
    if c4FolderCache and ((now - c4FolderCacheTime) < C4_FOLDER_TTL) then
        return c4FolderCache
    end

    local found = {}
    pcall(function()
        local function scan(container, depth)
            if not container or depth > 3 then return end
            for _, child in ipairs(container:GetChildren()) do
                if child:IsA("Folder") and child.Name == "C4" then
                    table.insert(found, child)
                elseif child:IsA("Folder") and depth < 3 then
                    -- only descend into plain folders, skip deep/huge trees
                    scan(child, depth + 1)
                end
            end
        end
        scan(Workspace, 0)
    end)

    -- Prune folders that were removed
    local alive = {}
    for _, f in ipairs(found) do
        if f and f.Parent then table.insert(alive, f) end
    end

    c4FolderCache = alive
    c4FolderCacheTime = now
    return alive
end

-- shallow search of a container for a bomb model (depth-limited, cheap)
local function shallowScan(container)
    if not container then return nil end
    for _, child in ipairs(container:GetChildren()) do
        if isBombName(child.Name) then
            if child:IsA("Model") or child:IsA("BasePart") or child:IsA("Folder") then
                return child
            end
        end
    end
    return nil
end

-- the physical bomb, outside the characters folder
local function findWorldBomb()
    -- 1. Known C4 folders (cheap, cached list)
    for _, c4Folder in ipairs(getC4Folders()) do
        local found = shallowScan(c4Folder)
        if found then return found end
    end

    -- 2. Debris / dropped items (cheap, top level only)
    local debris = Workspace:FindFirstChild("Debris")
    if debris then
        local found = shallowScan(debris)
        if found then return found end
    end

    -- 3. Workspace top level only (no deep recursion - keeps FPS stable)
    return shallowScan(Workspace)
end

local function bombAttributes()
    local planted = false
    local timer = 0

    pcall(function()
        planted = (LocalPlayer:GetAttribute("BombPlanted") == true)
        timer = tonumber(LocalPlayer:GetAttribute("BombTimer")) or 0
    end)

    return planted, timer
end

local function drawCarrier(camera, character, color)
    local item = makeItem("Carrier")
    if not item then return end

    local part = character:FindFirstChild("Head") or character:FindFirstChild("UpperTorso")
    if not part then
        item.Box.Visible = false
        item.Label.Visible = false
        return
    end

    local ok, screen = pcall(camera.WorldToViewportPoint, camera, part.Position + Vector3.new(0, 2, 0))

    if (not ok) or (not screen) or (screen.Z <= 0) then
        item.Box.Visible = false
        item.Label.Visible = false
        return
    end

    local player = Players:FindFirstChild(character.Name)
    local shown = (player and player.DisplayName) or character.Name

    pcall(function()
        item.Label.Text = "C4 Carrier: " .. tostring(shown)
        item.Label.Position = Vector2.new(screen.X, screen.Y)
        item.Label.Color = color
        item.Label.Visible = true
        item.Box.Visible = false
    end)
end

local function drawWorldBomb(camera, model, color, label)
    local item = makeItem("World")
    if not item then return end

    local ok, box, center = pcall(function()
        return model:GetBoundingBox()
    end)

    if (not ok) or (not box) or (not center) then
        item.Box.Visible = false
        item.Label.Visible = false
        return
    end

    local okScreen, screen = pcall(camera.WorldToViewportPoint, camera, center.Position)

    if (not okScreen) or (not screen) or (screen.Z <= 0) then
        item.Box.Visible = false
        item.Label.Visible = false
        return
    end

    local size = box.Size
    local width = math.max(size.X, size.Y, size.Z, 2)

    pcall(function()
        item.Box.Position = Vector2.new(screen.X - (width / 2), screen.Y - (width / 2))
        item.Box.Size = Vector2.new(width, width)
        item.Box.Color = color
        item.Box.Visible = true

        item.Label.Text = label
        item.Label.Position = Vector2.new(screen.X, screen.Y - (width / 2) - 16)
        item.Label.Color = color
        item.Label.Visible = true
    end)
end

-- Cache the expensive workspace scans. The recursive scan must NOT run
-- every frame - it walks the whole Workspace tree and tanks performance.
-- Results are refreshed on a timer instead.
local cache = {
    carrier = nil,
    carrierValid = false,
    worldBomb = nil,
    worldBombValid = false,
    lastCarrierScan = 0,
    lastBombScan = 0
}

local CARRIER_INTERVAL = 0.25
local BOMB_INTERVAL = 0.5

local function getCarrierCached()
    local now = os.clock()
    if (not cache.carrierValid) or ((now - cache.lastCarrierScan) >= CARRIER_INTERVAL) then
        cache.carrierValid = true
        cache.lastCarrierScan = now
        cache.carrier = findBombCarrier()
    end
    -- Drop the cached instance if it was removed from the game
    if cache.carrier and (not cache.carrier.Parent) then
        cache.carrier = nil
    end
    return cache.carrier
end

local function getWorldBombCached()
    local now = os.clock()
    if (not cache.worldBombValid) or ((now - cache.lastBombScan) >= BOMB_INTERVAL) then
        cache.worldBombValid = true
        cache.lastBombScan = now
        cache.worldBomb = findWorldBomb()
    end
    if cache.worldBomb and (not cache.worldBomb.Parent) then
        cache.worldBomb = nil
    end
    return cache.worldBomb
end

local function update()
    if not storedConfig then return end

    -- Default to enabled if not explicitly disabled
    local enabled = storedConfig.C4_ESP_ENABLED
    if enabled == nil then enabled = true end

    if not enabled then
        hideAll()
        return
    end

    local camera = getCamera()
    if not camera then
        hideAll()
        return
    end

    local color = Color3.fromRGB(255, 70, 70)

    -- Use cached scans instead of scanning every frame
    local carrier = getCarrierCached()

    if carrier then
        drawCarrier(camera, carrier, color)
    else
        local carrierItem = C4ESP.Items["Carrier"]
        if carrierItem then
            pcall(function()
                carrierItem.Box.Visible = false
                carrierItem.Label.Visible = false
            end)
        end
    end

    local planted, timer = bombAttributes()
    local worldBomb = getWorldBombCached()

    if worldBomb then
        local label

        if planted then
            label = string.format("C4 Planted  %.0fs", timer)
        else
            label = "C4 Dropped"
        end

        drawWorldBomb(camera, worldBomb, color, label)
    else
        local worldItem = C4ESP.Items["World"]
        if worldItem then
            pcall(function()
                worldItem.Box.Visible = false
                worldItem.Label.Visible = false
            end)
        end
    end
end

function C4ESP.init(Config)
    if C4ESP.Initialized then return end
    C4ESP.Initialized = true

    storedConfig = Config

    C4ESP.Connection = RunService.RenderStepped:Connect(function()
        pcall(update)
    end)
end

function C4ESP.cleanup()
    if C4ESP.Connection then
        pcall(function() C4ESP.Connection:Disconnect() end)
        C4ESP.Connection = nil
    end

    hideAll()

    for key, item in pairs(C4ESP.Items) do
        pcall(function()
            item.Box:Remove()
            item.Label:Remove()
        end)
        C4ESP.Items[key] = nil
    end

    storedConfig = nil
    C4ESP.Initialized = false
end

return C4ESP
