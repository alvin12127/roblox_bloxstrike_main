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
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
-- Built from an instance dump of the live game rather than from guessed
-- substrings. The previous matcher used {"c4", "bomb", "bombholster"}, which:
--   * flagged unrelated map objects (anything whose name merely contains "bomb")
--   * matched the C4 module and RemoteEvents in ReplicatedStorage
--   * still missed the planted bomb, whose name is not one of those
--
-- Names actually present in the game (from the dump):
--   Characters/<Player>
--     <Player>_WeaponAttachments          (Folder, PersistentDebris)
--       T Knife                            (Model)  <- the equipped knife model
--         Interactables                    (Folder)
--           BombHolster                    (Model, PrimaryPart "Body")  <- the C4
--
--   ReplicatedStorage
--     Components/C4                       (ModuleScript)   <- logic only
--     NetworkRemotes/C4                   (RemoteEvent)
--     Remotes: Planted, Defused, StartDefuse, CancelDefuse, BombSiteEntered ...
--
-- So the ONLY reliable client-side marker is the "BombHolster" Model, and it is
-- what gets tracked in every state: carried, dropped, and planted.

-- Exact instance names. No substring matching, so map geometry, UI and the C4
-- RemoteEvents can never be mistaken for the bomb.
local BOMB_MODEL_NAMES = {
    ["bombholster"] = true,
}

-- The C4 rig lives under a folder named "<Player>_WeaponAttachments".
local function isWeaponAttachmentsName(name)
    if type(name) ~= "string" then return false end
    return name:lower():find("_weaponattachments", 1, true) == 1
        or name:lower():find("weaponattachments", 1, true) ~= nil
end

local function isBombName(name)
    if type(name) ~= "string" then return false end
    return BOMB_MODEL_NAMES[name:lower()] == true
end

-- Find a BombHolster anywhere under a node, returning both the holster and the
-- owning character model when one is found.
local function findHolsterUnder(node, maxDepth)
    if not node then return nil, nil end
    maxDepth = maxDepth or 8

    local found = nil
    pcall(function()
        for _, d in ipairs(node:GetDescendants()) do
            if found then break end
            if d:IsA("Model") and isBombName(d.Name) then
                found = d
            end
        end
    end)
    if not found then return nil, nil end

    -- walk up to see whether we are inside a character
    local owner = nil
    local chars = Workspace:FindFirstChild("Characters")
    if chars then
        pcall(function()
            for _, c in ipairs(chars:GetChildren()) do
                if c:IsA("Model") and found:IsDescendantOf(c) then
                    owner = c
                    break
                end
            end
        end)
    end

    return found, owner
end

-- The C4 is a single "BombHolster" Model. From an instance dump of the live
-- game the real hierarchy is:
--
--   Characters                                     (Folder)
--     Terrorists / Counter-Terrorists / Hostages    (Folders, per team)
--       <Player>                                   (Model, the character)
--     <Player>_WeaponAttachments                   (Folder, PersistentDebris)
--       <Player>_Weapon                            (Model)
--         T Knife                                  (Model)
--           Interactables                          (Folder)
--             BombHolster                          (Model, PP "Body")
--
-- The critical detail: <Player>_WeaponAttachments is a SIBLING of the character
-- models, sitting directly under Characters - it is NOT a child of the player
-- model. An earlier version searched character:GetChildren() for it, which can
-- never find it, so the carrier was never resolved and the bomb was reported as
-- "Dropped" even while somebody was carrying it.
--
-- Because the attachment folder is named after its owner, the carrier is derived
-- from that name instead of from instance parentage.

local function ownerNameFromAttachment(name)
    if type(name) ~= "string" then return nil end
    return name:match("^(.-)_WeaponAttachments$")
        or name:match("^(.-)%.WeaponAttachments$")
        or name:match("^(.-)_WeaponAttachment$")
end

-- Every character model in the game, including the ones nested in team folders.
local function eachCharacter(fn)
    local charsFolder = Workspace:FindFirstChild("Characters")
    if not charsFolder then return end

    local seen = {}

    local function consider(node, depth)
        if depth > 3 then return end
        pcall(function()
            for _, child in ipairs(node:GetChildren()) do
                if not seen[child] then
                    seen[child] = true
                    -- a character model is identified by having a Humanoid
                    local hum = nil
                    pcall(function() hum = child:FindFirstChildOfClass("Humanoid") end)
                    if child:IsA("Model") and hum then
                        fn(child)
                    else
                        consider(child, depth + 1)
                    end
                end
            end
        end)
    end

    consider(charsFolder, 0)
end

-- Live character models keyed by lowercased name.
local function buildCharacterMap()
    local map = {}
    eachCharacter(function(char)
        local hum = nil
        pcall(function() hum = char:FindFirstChildOfClass("Humanoid") end)
        if (not hum) or (hum.Health > 0) then
            map[tostring(char.Name):lower()] = char
        end
    end)
    return map
end

-- Resolve the bomb and, if it is being carried, by whom.
--
-- Returns: holster, holderName, holderCharacter
local function scanForBomb()
    local charsFolder = Workspace:FindFirstChild("Characters")
    local chars = buildCharacterMap()

    -- 1. A BombHolster inside a <Name>_WeaponAttachments folder anywhere under
    --    Characters. Those folders are siblings of the character models, so the
    --    whole Characters subtree is walked instead of a single level.
    if charsFolder then
        local foundHolster, foundOwner, foundChar
        pcall(function()
            for _, d in ipairs(charsFolder:GetDescendants()) do
                if (not foundHolster) and d:IsA("Folder")
                    and isWeaponAttachmentsName(d.Name) then
                    local holster = findHolsterUnder(d)
                    if holster then
                        foundHolster = holster
                        foundOwner = ownerNameFromAttachment(d.Name)
                        foundChar = foundOwner and chars[foundOwner:lower()] or nil
                    end
                end
            end
        end)
        if foundHolster then
            return foundHolster, foundOwner, foundChar
        end
    end

    -- 2. A bomb welded directly to a character (some builds place it this way).
    local welded = nil
    local weldedName = nil
    local weldedChar = nil
    eachCharacter(function(char)
        if not welded then
            local holster = nil
            pcall(function() holster = findHolsterUnder(char) end)
            if holster then
                welded = holster
                weldedName = tostring(char.Name)
                weldedChar = char
            end
        end
    end)
    if welded then
        return welded, weldedName, weldedChar
    end

    -- 3. Loose in the world: dropped by a dead carrier, thrown, or planted.
    --    Every descendant is examined, because the game parents the bomb into
    --    Debris or a map folder several levels down.
    local best = nil
    local bestDepth = nil

    pcall(function()
        for _, child in ipairs(Workspace:GetChildren()) do
            if child:IsA("Model") and isBombName(child.Name) then
                best, bestDepth = child, 0
            end
            for _, d in ipairs(child:GetDescendants()) do
                if d:IsA("Model") and isBombName(d.Name) then
                    local depth = 0
                    pcall(function()
                        local n = d.Parent
                        while n and n ~= Workspace do
                            depth = depth + 1
                            n = n.Parent
                        end
                    end)
                    if (not bestDepth) or (depth < bestDepth) then
                        best, bestDepth = d, depth
                    end
                end
            end
        end
    end)

    return best, nil, nil
end

-- Bomb state. The dump shows the game drives this through Remotes rather than
-- player attributes, so several sources are checked.
local function bombAttributes()
    local planted = false
    local timer = 0

    -- player attributes
    pcall(function()
        if LocalPlayer:GetAttribute("BombPlanted") == true then planted = true end
        timer = tonumber(LocalPlayer:GetAttribute("BombTimer")) or 0
    end)
    if planted then return true, timer end

    -- character attributes
    pcall(function()
        local char = LocalPlayer.Character
        if char then
            if char:GetAttribute("BombPlanted") == true then planted = true end
            timer = tonumber(char:GetAttribute("BombTimer")) or timer
        end
    end)
    if planted then return true, timer end

    -- a value object in ReplicatedStorage holding the countdown
    if timer <= 0 then
        pcall(function()
            local remotes = ReplicatedStorage:FindFirstChild("Remotes")
            local holder = (remotes and remotes:FindFirstChild("BombTimer"))
                or ReplicatedStorage:FindFirstChild("BombTimer")
            if holder and holder.Value ~= nil then
                timer = tonumber(holder.Value) or 0
            end
        end)
    end

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

    -- Off screen: clamp a marker onto the screen edge so the bomb can still be
    -- located. Hiding it entirely made the feature look broken whenever the bomb
    -- was not directly in front of the player.
    if (screen.X < 0) or (screen.Y < 0)
        or (screen.X > viewport.X) or (screen.Y > viewport.Y) then
        local cx = viewport.X / 2
        local cy = viewport.Y / 2
        local dx = screen.X - cx
        local dy = screen.Y - cy

        -- Inset well away from the very edge so the marker is not clipped by the
        -- screen border and is not hidden under the debug readout in the corner.
        local marginX = 90
        local marginY = 90
        local halfW = (viewport.X / 2) - marginX
        local halfH = (viewport.Y / 2) - marginY
        if halfW < 40 then halfW = 40 end
        if halfH < 40 then halfH = 40 end

        local scale = math.huge
        if math.abs(dx) > 0.0001 then scale = math.min(scale, halfW / math.abs(dx)) end
        if math.abs(dy) > 0.0001 then scale = math.min(scale, halfH / math.abs(dy)) end
        if scale == math.huge then scale = 1 end

        local ax = cx + (dx * scale)
        local ay = cy + (dy * scale)

        -- Final hard clamp: scale alone can overshoot when one axis dominates.
        ax = math.max(marginX * 0.5, math.min(viewport.X - marginX * 0.5, ax))
        ay = math.max(marginY * 0.5, math.min(viewport.Y - marginY * 0.5, ay))

        local dist = math.floor(screen.Z)

        pcall(function()
            -- A filled square plus a bigger label: the previous thin outline at
            -- 1.5px was very easy to miss at the screen edge.
            item.Box.Position = Vector2.new(ax - 15, ay - 15)
            item.Box.Size = Vector2.new(30, 30)
            item.Box.Thickness = 3
            item.Box.Filled = true
            item.Box.Transparency = 0.35
            item.Box.Color = color
            item.Box.ZIndex = 50
            item.Box.Visible = true

            item.Label.Text = string.format("%s  %dm", tostring(label), dist)
            item.Label.Size = 15
            item.Label.Outline = true
            item.Label.Center = true
            item.Label.Position = Vector2.new(ax, ay - 30)
            item.Label.Color = Color3.fromRGB(255, 240, 90)
            item.Label.ZIndex = 51
            item.Label.Visible = true
        end)

        stateLog("bomb off screen - edge marker at ("
            .. tostring(math.floor(ax)) .. ", " .. tostring(math.floor(ay))
            .. ") dist=" .. tostring(dist) .. "m")
        return
    end

    local okDraw = pcall(function()
        item.Box.Position = Vector2.new(screen.X - (width / 2), screen.Y - (width / 2))
        item.Box.Size = Vector2.new(width, width)
        item.Box.Thickness = 1.5
        item.Box.Filled = false
        item.Box.Transparency = 0
        item.Box.ZIndex = 2
        item.Box.Color = color
        item.Box.Visible = true

        item.Label.Text = label
        item.Label.Size = 13
        item.Label.Position = Vector2.new(screen.X, screen.Y - (width / 2) - 16)
        item.Label.Color = color
        item.Label.ZIndex = 3
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
    worldBomb = nil,
    carrierName = nil,
    carrier = nil,
    worldBombValid = false,
    lastBombScan = 0
}

local BOMB_INTERVAL = 0.35

-- The scan is the expensive part, so it runs once per interval and every piece
-- of state (bomb, carrier name, carrier character) is read from the same result.
-- Running separate scans per value is what previously let the label and the
-- marker disagree about whether the bomb was carried.
local function refreshScan()
    local now = os.clock()
    if (not cache.worldBombValid) or ((now - cache.lastBombScan) >= BOMB_INTERVAL) then
        cache.worldBombValid = true
        cache.lastBombScan = now

        local holster, ownerName, char = scanForBomb()
        cache.worldBomb = holster
        cache.carrierName = ownerName
        cache.carrier = char
    end

    -- A destroyed bomb must be reported as gone immediately, otherwise its marker
    -- keeps drawing at the last known position for a whole scan interval. The
    -- carrier has to be cleared with it: when the carrier dies, the attachment
    -- folder is destroyed and a new holster appears elsewhere, so a stale cached
    -- name would keep labelling the dropped bomb as carried.
    if cache.worldBomb and (not cache.worldBomb.Parent) then
        cache.worldBomb = nil
        cache.carrierName = nil
        cache.carrier = nil
        cache.worldBombValid = false
    end

    if cache.carrier and (not cache.carrier.Parent) then
        cache.carrier = nil
        cache.carrierName = nil
    end
end

local function getWorldBombCached()
    refreshScan()
    return cache.worldBomb
end

local function getCarrierNameCached()
    refreshScan()
    return cache.carrierName
end

local function getCarrierCharCached()
    refreshScan()
    return cache.carrier
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

    -- One scan answers everything: where the bomb is and who is holding it.
    local worldBomb = getWorldBombCached()
    local carrierName = getCarrierNameCached()
    local carrierChar = getCarrierCharCached()

    if carrierChar then
        drawCarrier(camera, carrierChar, color)
    else
        hideItem("Carrier")
    end

    local planted, timer = bombAttributes()

    -- On-screen debug readout (top-left, yellow) so the state is visible even
    -- when every console is blocked.
    ensureDebugLabel()
    pcall(function()
        if debugText then
            debugText.Visible = true
            -- Also report whether the bomb is on screen or clamped to an edge,
            -- because that is the single most useful thing when it looks broken.
            local where = "none"
            if worldBomb then
                where = "found"
                local cam = Workspace.CurrentCamera
                if cam then
                    local okp, sp = pcall(function()
                        return cam:WorldToViewportPoint(resolvePosition(worldBomb, 0) or Vector3.new())
                    end)
                    if okp and sp and typeof(sp) == "Vector3" then
                        local vs = cam.ViewportSize
                        if sp.X < 0 or sp.Y < 0 or sp.X > vs.X or sp.Y > vs.Y then
                            where = "OFF-SCREEN (edge marker)"
                        else
                            where = string.format("on screen (%.0f,%.0f)", sp.X, sp.Y)
                        end
                    end
                end
            end
            debugText.Text = string.format(
                "C4 ESP  carrier=%s\nbomb=%s\nstatus=%s",
                tostring(carrierName) or "none",
                tostring(worldBomb and worldBomb.Name) or "none",
                where
            )
        end
    end)

    if worldBomb then
        -- One rule decides the label, using the same scan that located the bomb:
        --
        --   a <Name>_WeaponAttachments folder owns it -> C4 Carrier: <name>  (red)
        --   the game reports it planted               -> C4 Planted <timer>  (amber)
        --   otherwise (thrown, or dropped by a corpse)-> C4 Dropped          (green)
        --
        -- Nothing is derived from "is it under a character", because the bomb is
        -- NOT parented to the character - it hangs off a sibling folder named
        -- after the owner. That was the source of the wrong "Dropped" label.
        local label
        local markerColor = color

        if carrierName then
            label = "C4 Carrier: " .. tostring(carrierName)
        elseif planted then
            label = string.format("C4 Planted  %.0fs", timer)
            markerColor = Color3.fromRGB(255, 170, 40)
        else
            label = "C4 Dropped"
            markerColor = Color3.fromRGB(90, 230, 120)
        end

        drawWorldBomb(camera, worldBomb, markerColor, label)
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

    cache.worldBomb = nil
    cache.carrierName = nil
    cache.carrier = nil
    cache.worldBombValid = false
    cache.lastBombScan = 0
    lastState = ""

    storedConfig = nil
    C4ESP.Initialized = false
end

return C4ESP
