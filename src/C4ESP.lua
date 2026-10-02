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
-- world bomb 0.5s). Never scan the tree every frame.

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

-- ==========================================================
-- Diagnostics
-- ==========================================================
-- Some executors block Roblox's F9 output entirely, so the executor console
-- APIs are tried first and warn() is only the fallback.
local function execLog(msg)
    local line = "[Bloxstrike] C4 ESP: " .. msg
    local written = false

    pcall(function()
        if rconsoleprint then rconsoleprint(line .. "\n"); written = true end
    end)
    if not written then
        pcall(function()
            if consoleprint then consoleprint(line .. "\n"); written = true end
        end)
    end
    if not written then
        pcall(function()
            if printconsole then printconsole(line); written = true end
        end)
    end

    pcall(function() warn(line) end)
end

-- State-change logger.
--
-- A plain time throttle cannot be used here: the "about to draw" message
-- fires every frame and would consume the whole throttle budget, so every
-- message emitted *inside* the draw function was silently swallowed forever.
-- Logging only when the message text actually changes guarantees the reason
-- the marker is not appearing is always visible.
local lastState = ""
local function stateLog(msg)
    if msg ~= lastState then
        lastState = msg
        execLog(msg)
    end
end

-- On-screen debug readout so the state is visible even when every console is
-- blocked.
local debugText = nil
local function ensureDebugLabel()
    if debugText then return end
    pcall(function()
        debugText = Drawing.new("Text")
        debugText.Size = 13
        debugText.Center = false
        debugText.Outline = true
        debugText.Color = Color3.fromRGB(255, 220, 0)
        debugText.Position = Vector2.new(16, 150)
        debugText.Visible = false
        debugText.Text = ""
    end)
end

-- ==========================================================
-- Drawing primitives
-- ==========================================================
local function makeItem(key)
    local item = C4ESP.Items[key]
    if item then return item end

    local okBox, box = pcall(function() return Drawing.new("Square") end)
    local okText, label = pcall(function() return Drawing.new("Text") end)

    if (not okBox) or (not okText) or (not box) or (not label) then
        if okBox and box then pcall(function() box:Remove() end) end
        if okText and label then pcall(function() label:Remove() end) end
        return nil
    end

    pcall(function()
        box.Thickness = 1.5
        box.Filled = false
        box.Visible = false
        box.ZIndex = 2

        label.Size = 13
        label.Center = true
        label.Outline = true
        label.Visible = false
        label.ZIndex = 3
    end)

    item = { Box = box, Label = label }
    C4ESP.Items[key] = item

    return item
end

local function hideItem(key)
    local item = C4ESP.Items[key]
    if not item then return end
    pcall(function() item.Box.Visible = false end)
    pcall(function() item.Label.Visible = false end)
end

local function hideAll()
    for key in pairs(C4ESP.Items) do
        hideItem(key)
    end
end

-- ==========================================================
-- Position resolution
-- ==========================================================
-- Resolve a world position from any kind of instance.
--
-- NOTE: Instance:GetBoundingBox() returns (CFrame, Vector3) - the CFrame comes
-- FIRST and the size SECOND. Reading them the other way round (the old bug)
-- made `cf.Size` and `sz.Position` both nil, so every single marker silently
-- bailed out with "no position" and nothing was ever drawn.
local function resolvePosition(inst, depth)
    if not inst then return nil end
    depth = (depth or 0)

    if inst:IsA("BasePart") then
        local ok, p = pcall(function() return inst.Position end)
        if ok and p then return p end
        return nil
    end

    if inst:IsA("Attachment") then
        local ok, p = pcall(function() return inst.WorldPosition end)
        if ok and p then return p end
        return nil
    end

    if inst:IsA("Model") then
        local ok, cf = pcall(function() return inst:GetBoundingBox() end)
        if ok and cf and typeof(cf) == "CFrame" then
            local okPos, p = pcall(function() return cf.Position end)
            if okPos and p then return p end
        end

        -- GetBoundingBox can fail when the model has no PrimaryPart
        if depth < 3 then
            local part = nil
            pcall(function() part = inst.PrimaryPart end)
            if not part then
                pcall(function() part = inst:FindFirstChildWhichIsA("BasePart") end)
            end
            if part then
                local okPos, p = pcall(function() return part.Position end)
                if okPos and p then return p end
            end
        end
    end

    -- Folders / other containers: use the first child that resolves
    if depth < 4 then
        local kids = nil
        pcall(function() kids = inst:GetChildren() end)
        if kids then
            for _, child in ipairs(kids) do
                local p = resolvePosition(child, depth + 1)
                if p then return p end
            end
        end
    end

    return nil
end

-- ==========================================================
-- Detection
-- ==========================================================
-- Name matching: the scan technique is taken from the GrenadeESP module
-- (workspace scan by name substring) but the hints are deliberately NARROW.
-- Broad hints (grenade / smoke / molotov) flag everything, which is why that
-- attempt got scrapped. Only C4 / bomb names are accepted here.
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

-- The bomb carrier has the C4 strapped to the rig (on the back). Two different
-- hierarchies were observed in game, so both are handled:
--   1. a bomb-named instance somewhere under the character model
--   2. a "<PlayerName>_WeaponAttachments" folder living directly in Workspace
--      that holds the BombHolster
local function findCarrierByWeaponAttachments()
    local target = nil

    pcall(function()
        for _, holder in ipairs(Workspace:GetChildren()) do
            if holder:IsA("Folder") or holder:IsA("Model") then
                local hn = tostring(holder.Name)
                if hn:lower():find("weaponattachment", 1, true) then
                    for _, d in ipairs(holder:GetDescendants()) do
                        if isBombName(d.Name) then
                            target = hn
                            break
                        end
                    end
                end
            end
            if target then break end
        end
    end)

    if not target then return nil end

    -- "kewgtiv_WeaponAttachments" -> "kewgtiv"
    local owner = target:match("^(.-)_WeaponAttachments")
                or target:match("^(.-)%.WeaponAttachments")
    if not owner then return nil end

    local player = Players:FindFirstChild(owner)
    if player then
        local character = nil
        pcall(function() character = player.Character end)
        if character then return character end
    end

    -- Player object missing - fall back to the matching character model
    local characters = Workspace:FindFirstChild("Characters")
    if characters then
        for _, c in ipairs(characters:GetChildren()) do
            if c:IsA("Model") and (tostring(c.Name):lower() == tostring(owner):lower()) then
                return c
            end
        end
    end

    return nil
end

local function findBombCarrier()
    local characters = Workspace:FindFirstChild("Characters")
    if not characters then return findCarrierByWeaponAttachments() end

    for _, character in ipairs(characters:GetChildren()) do
        if character:IsA("Model") and (character ~= LocalPlayer.Character) then
            -- 1. Named holder anywhere under the character
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
            if holder then return character end
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
            if hasBomb then return character end

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
                if pHas then return character end
            end
        end
    end

    return findCarrierByWeaponAttachments()
end

-- Priority: a bomb sitting loose in the world (Debris / map folders) is far
-- more useful than the holster model riding on the carrier's back, so loose
-- instances win when several candidates match.
local function bombPriority(inst)
    local score = 0

    local parentName = ""
    pcall(function() parentName = tostring(inst.Parent and inst.Parent.Name) end)
    local lowerParent = parentName:lower()

    if lowerParent:find("debris", 1, true) then score = score + 40 end
    if lowerParent:find("weaponattachment", 1, true) then score = score - 20 end
    if lowerParent == "workspace" then score = score - 30 end

    local own = inst.Name:lower()
    if own == "c4" or own == "bomb" then score = score + 10 end
    if own:find("bombholster", 1, true) then score = score - 5 end
    -- GUID style names are renamed instances (debris) - still useful, but only
    -- when nothing better exists
    if own:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-") then score = score - 5 end

    return score
end

-- The physical bomb. Uses the GrenadeESP scan technique: walk the workspace
-- three levels deep and match by name substring. Characters are excluded so
-- the carrier's rig is never mistaken for a dropped bomb.
local function findWorldBomb()
    local charsFolder = Workspace:FindFirstChild("Characters")
    local localChar = LocalPlayer and LocalPlayer.Character
    local best = nil
    local bestScore = nil

    local function consider(inst)
        if not inst then return end
        if not (inst:IsA("BasePart") or inst:IsA("Model") or inst:IsA("Folder")) then return end

        -- skip anything parented under a player rig
        if charsFolder and inst:IsDescendantOf(charsFolder) then return end
        if localChar and inst:IsDescendantOf(localChar) then return end

        -- skip the first person viewmodel (it lives under the Camera)
        local underCamera = false
        pcall(function() underCamera = inst:IsDescendantOf(Workspace.CurrentCamera) end)
        if underCamera then return end

        if not isBombName(inst.Name) then return end
        -- must actually resolve to somewhere on the map
        if not resolvePosition(inst, 0) then return end

        local score = bombPriority(inst)
        if (not bestScore) or (score > bestScore) then
            best = inst
            bestScore = score
        end
    end

    pcall(function()
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
    end)

    return best
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

-- ==========================================================
-- Draw
-- ==========================================================
local function drawCarrier(camera, character, color)
    local item = makeItem("Carrier")
    if not item then return end

    local part = character:FindFirstChild("Head") or character:FindFirstChild("UpperTorso")
    if not part then
        hideItem("Carrier")
        return
    end

    local ok, screen = pcall(camera.WorldToViewportPoint, camera, part.Position + Vector3.new(0, 2, 0))

    if (not ok) or (not screen) or (screen.Z <= 0) then
        hideItem("Carrier")
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

local function drawWorldBomb(camera, inst, color, label)
    local item = makeItem("World")
    if not item then
        stateLog("draw failed - Drawing library unavailable")
        return
    end

    local position = resolvePosition(inst, 0)

    if not position then
        stateLog("draw failed - no position resolved for '" .. tostring(inst.Name)
            .. "' (class=" .. tostring(inst.ClassName) .. ")")
        hideItem("World")
        return
    end

    local okScreen, screen = pcall(camera.WorldToViewportPoint, camera, position)

    if (not okScreen) or (not screen) or (screen.Z <= 0) then
        stateLog("draw failed - '" .. tostring(inst.Name) .. "' is behind the camera (Z="
            .. tostring(screen and screen.Z) .. ")")
        hideItem("World")
        return
    end

    -- Fixed pixel size, same as the GrenadeESP module. Feeding world-space size
    -- straight into pixel dimensions collapses the box to ~2px (invisible) as
    -- soon as the bomb is more than a few studs away. A constant keeps the
    -- marker readable at any distance.
    local width = 26

    local viewport = camera.ViewportSize
    if (screen.X < -width) or (screen.Y < -width)
        or (screen.X > viewport.X + width) or (screen.Y > viewport.Y + width) then
        stateLog("draw failed - '" .. tostring(inst.Name) .. "' is off screen at ("
            .. tostring(math.floor(screen.X)) .. ", " .. tostring(math.floor(screen.Y)) .. ")")
        hideItem("World")
        return
    end

    local okDraw = pcall(function()
        item.Box.Position = Vector2.new(screen.X - (width / 2), screen.Y - (width / 2))
        item.Box.Size = Vector2.new(width, width)
        item.Box.Color = color
        item.Box.Visible = true

        item.Label.Text = label
        item.Label.Position = Vector2.new(screen.X, screen.Y - (width / 2) - 16)
        item.Label.Color = color
        item.Label.Visible = true
    end)

    if okDraw then
        stateLog("drawing '" .. tostring(inst.Name) .. "' at ("
            .. tostring(math.floor(screen.X)) .. ", " .. tostring(math.floor(screen.Y))
            .. ") Z=" .. tostring(math.floor(screen.Z)))
    else
        stateLog("draw failed - Drawing write error on '" .. tostring(inst.Name) .. "'")
        hideItem("World")
    end
end

-- ==========================================================
-- Caching
-- ==========================================================
-- The workspace scans must NOT run every frame - they walk the whole tree.
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

-- ==========================================================
-- Update loop
-- ==========================================================
local function update()
    if not storedConfig then return end

    local enabled = storedConfig.C4_ESP_ENABLED
    if enabled == nil then enabled = true end

    if not enabled then
        hideAll()
        ensureDebugLabel()
        pcall(function()
            if debugText then debugText.Visible = false end
        end)
        lastState = ""
        return
    end

    local camera = Workspace.CurrentCamera
    if not camera then
        hideAll()
        return
    end

    local color = Color3.fromRGB(255, 70, 70)

    local carrier = getCarrierCached()

    if carrier then
        drawCarrier(camera, carrier, color)
    else
        hideItem("Carrier")
    end

    local planted, timer = bombAttributes()
    local worldBomb = getWorldBombCached()

    -- On-screen debug readout (top-left, yellow) so the state is visible even
    -- when every console is blocked.
    ensureDebugLabel()
    pcall(function()
        if debugText then
            debugText.Visible = true
            debugText.Text = string.format(
                "C4 ESP  enabled=%s\ncarrier=%s\nbomb=%s",
                tostring(enabled),
                tostring(carrier and carrier.Name) or "none",
                tostring(worldBomb and worldBomb.Name) or "none"
            )
        end
    end)

    if worldBomb then
        local label
        if planted then
            label = string.format("C4 Planted  %.0fs", timer)
        else
            label = "C4 Dropped"
        end

        drawWorldBomb(camera, worldBomb, color, label)
    else
        hideItem("World")
        stateLog("no bomb instance found in workspace yet")
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

    if debugText then
        pcall(function() debugText:Remove() end)
        debugText = nil
    end

    for key, item in pairs(C4ESP.Items) do
        pcall(function()
            item.Box:Remove()
            item.Label:Remove()
        end)
        C4ESP.Items[key] = nil
    end

    cache.carrier = nil
    cache.carrierValid = false
    cache.worldBomb = nil
    cache.worldBombValid = false
    lastState = ""

    storedConfig = nil
    C4ESP.Initialized = false
end

return C4ESP
