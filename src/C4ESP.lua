-- c4 esp
-- Dedicated bomb tracker, kept completely separate from the grenade code.
--
-- Ground truth confirmed in game:
--   * the carrier has the C4 strapped to the rig (on the back) - it is a
--     Model/BasePart somewhere inside the character tree, NOT always a
--     direct "BombHolster" child, so the whole character is scanned
--   * when the carrier dies the C4 drops into the world (C4 folder / Debris)
--     and is tracked there too
--   * planted / dropped state comes from the local player's own attributes
--
-- What is drawn:
--   * "C4 Carrier: <name>" above whoever is carrying the bomb
--   * a box plus a label on the physical bomb when it is on the ground, and the
--     remaining timer when it is planted.
--
-- Performance: the expensive workspace scans are cached (carrier 0.25s,
-- world bomb 0.5s, C4 folder list 10s). Never scan the tree every frame.

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

-- the bomb carrier has the C4 strapped to the rig (on the back).
-- The C4 is a Model/BasePart parented somewhere inside the character - it
-- is NOT always a direct "BombHolster" child. Scan the whole character
-- tree for anything named C4 / Bomb, which is what made the earlier
-- grenade ESP attempt detect it correctly.
local function findBombCarrier()
    local characters = Workspace:FindFirstChild("Characters")
    if not characters then return nil end

    for _, character in ipairs(characters:GetChildren()) do
        if character:IsA("Model") then
            -- 1. Named holder parented anywhere under the character
            local holder = nil
            pcall(function()
                for _, d in ipairs(character:GetDescendants()) do
                    if d:IsA("Model") or d:IsA("Folder") or d:IsA("BasePart") then
                        local n = d.Name:lower()
                        if n:find("bombholster", 1, true)
                            or n:find("c4", 1, true)
                            or n:find("bomb", 1, true) then
                            holder = d
                            break
                        end
                    end
                end
            end)
            if holder then
                return character
            end
        end

        do
            -- 2. Attribute based fallback (works for any character type)
            local hasBomb = false
            pcall(function()
                hasBomb = (character:GetAttribute("HasBomb") == true)
                    or (character:GetAttribute("Bomb") == true)
                    or (character:GetAttribute("HasC4") == true)
                    or (character:GetAttribute("C4") == true)
            end)
            if hasBomb then
                return character
            end

            -- 3. Player attribute fallback
            local player = Players:FindFirstChild(character.Name)
            if player then
                local pHas = false
                pcall(function()
                    pHas = (player:GetAttribute("HasBomb") == true)
                        or (player:GetAttribute("Bomb") == true)
                        or (player:GetAttribute("HasC4") == true)
                        or (player:GetAttribute("C4") == true)
                end)
                if pHas then
                    return character
                end
            end
        end
    end

    return nil
end

-- Name matching: the scan technique is taken from the GrenadeESP module
-- (workspace scan by name substring) but the hints are deliberately NARROW.
-- The old grenade attempt matched grenade/smoke/molotov/flash too, which made
-- it flag everything and got it scrapped. Only C4 / bomb names are accepted
-- here so the bomb is tracked without the noise.
local BOMB_HINTS = {
    "c4", "bomb", "bombholster"
}

local function isBombName(name)
    if type(name) ~= "string" then return false end
    local lower = name:lower()

    for _, hint in ipairs(BOMB_HINTS) do
        if lower:find(hint, 1, true) then
            return true
        end
    end

    return false
end

-- The physical bomb. Uses the GrenadeESP scan technique: walk the workspace
-- three levels deep and match by name substring. Characters are excluded so
-- the carrier's rig is never mistaken for a dropped bomb (the carrier is
-- handled separately by findBombCarrier).
local function findWorldBomb()
    local charsFolder = Workspace:FindFirstChild("Characters")
    local foundBomb = nil

    local function matches(inst)
        if not inst then return false end
        if not (inst:IsA("BasePart") or inst:IsA("Model")) then return false end
        -- skip anything parented under a player rig
        if charsFolder and inst:IsDescendantOf(charsFolder) then return false end
        return isBombName(inst.Name)
    end

    pcall(function()
        for _, child in ipairs(Workspace:GetChildren()) do
            if child ~= charsFolder then
                if matches(child) then
                    foundBomb = child
                    return
                end
                for _, sub in ipairs(child:GetChildren()) do
                    if matches(sub) then
                        foundBomb = sub
                        return
                    end
                    for _, leaf in ipairs(sub:GetChildren()) do
                        if matches(leaf) then
                            foundBomb = leaf
                            return
                        end
                    end
                end
            end
        end
    end)

    return foundBomb
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

local bombDiagLogged = false

local function drawWorldBomb(camera, model, color, label)
    local item = makeItem("World")
    if not item then
        if not bombDiagLogged then
            bombDiagLogged = true
            warn("[Bloxstrike] C4 ESP: draw skipped - no drawing item for 'World'")
        end
        return
    end

    -- Resolve a world position and a size. GetBoundingBox() fails on models
    -- without a PrimaryPart, so fall back to any BasePart they contain.
    local position = nil
    local size = nil

    local okBox, box, center = pcall(function()
        return model:GetBoundingBox()
    end)

    if okBox and box and center then
        position = center.Position
        size = box.Size
    else
        pcall(function()
            local part = model.PrimaryPart or model:FindFirstChildOfClass("BasePart")
            if part then
                position = part.Position
                size = part.Size
            end
        end)
    end

    if not position then
        if not bombDiagLogged then
            bombDiagLogged = true
            warn("[Bloxstrike] C4 ESP: draw skipped - no position for "
                .. tostring(model.Name) .. " (GetBoundingBox failed)")
        end
        item.Box.Visible = false
        item.Label.Visible = false
        return
    end

    local okScreen, screen = pcall(camera.WorldToViewportPoint, camera, position)

    if (not okScreen) or (not screen) or (screen.Z <= 0) then
        if not bombDiagLogged then
            bombDiagLogged = true
            warn("[Bloxstrike] C4 ESP: draw skipped - behind camera or off screen (Z="
                .. tostring(screen and screen.Z) .. ") for " .. tostring(model.Name))
        end
        item.Box.Visible = false
        item.Label.Visible = false
        return
    end

    -- Reached the drawing stage: clear the diag flag so a later failure logs again
    bombDiagLogged = false

    -- Fixed pixel size, same as the GrenadeESP module. Feeding world-space size
    -- straight into pixel dimensions collapses the box to ~2px (invisible) as
    -- soon as the bomb is more than a few studs away. A constant keeps the
    -- marker readable at any distance.
    local width = 26

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

local lastCarrierState = false
local lastBombState = false
local debugLogged = false

local function update()
    if not storedConfig then return end

    -- Default to enabled if not explicitly disabled
    local enabled = storedConfig.C4_ESP_ENABLED
    if enabled == nil then enabled = true end

    -- One-shot diagnostics so it is clear whether the feature is on and how
    -- many characters were inspected for the bomb.
    if not debugLogged then
        debugLogged = true
        pcall(function()
            local chars = Workspace:FindFirstChild("Characters")
            local n = chars and #chars:GetChildren() or 0
            warn("[Bloxstrike] C4 ESP: enabled=" .. tostring(enabled)
                .. " charactersFolder=" .. tostring(chars ~= nil)
                .. " characters=" .. tostring(n))

            if chars then
                for _, c in ipairs(chars:GetChildren()) do
                    local names = {}
                    for _, d in ipairs(c:GetDescendants()) do
                        local ln = d.Name:lower()
                        if ln:find("bomb", 1, true) or ln:find("c4", 1, true) then
                            table.insert(names, d.Name)
                        end
                    end
                    if #names > 0 then
                        warn("[Bloxstrike] C4 ESP: '" .. tostring(c.Name)
                            .. "' has bomb parts: " .. table.concat(names, ", "))
                    end
                end
            end
        end)
    end

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

    -- One-shot console message when the carrier appears. C4ESP has no
    -- reference to the UI library, so this uses warn() - it shows up in the
    -- executor console (F9) and confirms the detection actually fired.
    if carrier and (not lastCarrierState) then
        pcall(function()
            local nm = carrier.Name
            local pl = Players:FindFirstChild(nm)
            if pl and pl.DisplayName then nm = pl.DisplayName end
            warn("[Bloxstrike] C4 ESP carrier detected: " .. tostring(nm))
        end)
    end
    lastCarrierState = carrier and true or false

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

    -- One-shot console message when the world (dropped) bomb is found
    if worldBomb and (not lastBombState) then
        pcall(function()
            warn("[Bloxstrike] C4 ESP world bomb detected: " .. tostring(worldBomb.Name)
                .. " (parent: " .. tostring(worldBomb.Parent and worldBomb.Parent.Name) .. ")")
        end)
    end
    lastBombState = worldBomb and true or false

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
