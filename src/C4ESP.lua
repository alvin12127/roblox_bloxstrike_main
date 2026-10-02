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
        debugText.Size = 16
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

    -- The off-screen bearing marker. Optional: an executor without
    -- Drawing.new("Triangle") still gets a working on-screen marker, so failure
    -- here must not abort makeItem.
    local okArrow, arrow = pcall(function() return Drawing.new("Triangle") end)
    if (not okArrow) or (not arrow) then arrow = nil end

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

    if arrow then
        pcall(function()
            arrow.Filled = true
            arrow.Transparency = 0.15
            arrow.Thickness = 2
            arrow.Outline = true
            arrow.Visible = false
            arrow.ZIndex = 50
        end)
    end

    item = { Box = box, Label = label, Arrow = arrow }
    C4ESP.Items[key] = item

    return item
end

local function hideItem(key)
    local item = C4ESP.Items[key]
    if not item then return end
    pcall(function() item.Box.Visible = false end)
    pcall(function() item.Label.Visible = false end)
    if item.Arrow then
        pcall(function() item.Arrow.Visible = false end)
    end
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
-- game the real layout is:
--
--   Characters                                  (Folder)
--     <Player>                                   (Model - the character)
--       @CharacterName / @Dead / @Health        (attributes)
--       WeaponAttachments                       (Folder, inside the character)
--     <Player>_WeaponAttachments                (Folder, SIBLING of the models)
--       <Player>_Weapon                         (Model)
--         T Knife                               (Model)
--           Interactables                       (Folder)
--             BombHolster                       (Model, PP "Body")
--
-- Two details matter, and both were wrong in earlier versions:
--
--   1. EVERY character owns a "WeaponAttachments" folder, but only the carrier
--      gets an extra "<Player>_WeaponAttachments" sibling that actually holds the
--      BombHolster. So the folder's mere existence means nothing - what matters
--      is whether a BombHolster is inside it.
--
--   2. <Player>_WeaponAttachments is a SIBLING of the character models, not a
--      child of one. An earlier version searched character:GetChildren() for
--      it, which can never find it, so the carrier was never resolved and the
--      bomb was reported as "Dropped" while somebody was carrying it.
--
-- Because the attachment folder is named after its owner, the carrier is derived
-- from that name rather than from instance parentage.

-- Liveness. The rigs expose @Dead / @Health attributes; there is no Humanoid on
-- a character model at all, so the attribute is the only reliable signal (the
-- Humanoid fallback below is kept for rigs from a future build that add one).
-- A corpse keeps its attachment folder, so without this the ESP kept reporting a
-- dead body as the carrier and the real bomb on the floor was never shown.
local function isAlive(char)
    local dead, health = nil, nil
    pcall(function() dead = char:GetAttribute("Dead") end)
    pcall(function() health = tonumber(char:GetAttribute("Health")) end)

    if dead == true then return false end
    if dead == false then return true end
    if health and health <= 0 then return false end

    local hum = nil
    pcall(function() hum = char:FindFirstChildOfClass("Humanoid") end)
    if hum then
        local ok, h = pcall(function() return hum.Health end)
        if ok and type(h) == "number" then return h > 0 end
    end

    return true
end

local function ownerNameFromAttachment(name)
    if type(name) ~= "string" then return nil end
    return name:match("^(.-)_WeaponAttachments$")
        or name:match("^(.-)%.WeaponAttachments$")
        or name:match("^(.-)_WeaponAttachment$")
end

-- Every character model in the game, including the ones nested in team folders.
-- A player rig in this game is a Model with an @CharacterName attribute and
-- @Dead / @Health attributes. It does NOT contain a Humanoid - the dump shows
-- zero [Humanoid] instances under Characters, only custom rigs (IDF,
-- Anarchist, ...) built from BaseParts and an Animator. An earlier version
-- identified characters by FindFirstChildOfClass("Humanoid"), which therefore
-- matched nothing: the character map came back empty and the carrier was never
-- resolved, so a carried bomb was always labelled "Dropped".
local function isCharacterModel(inst)
    if not inst or (not inst:IsA("Model")) then return false end

    local charName = nil
    pcall(function() charName = inst:GetAttribute("CharacterName") end)
    if type(charName) == "string" and charName ~= "" then return true end

    -- Fallback for a rig that lacks the attribute: having a HumanoidRootPart is
    -- enough, because nothing else under Characters is a Model with one.
    local hasRoot = false
    pcall(function() hasRoot = inst:FindFirstChild("HumanoidRootPart") ~= nil end)
    return hasRoot
end

-- Visit every FOLDER under `root`, up to `maxDepth`, without ever descending
-- into a Model.
--
-- This is the single most important helper in the file. `Characters` holds a
-- dozen rigs of several hundred BaseParts each, and the earlier code called
-- GetDescendants() on the whole folder several times per scan. That is slow,
-- and - worse - every one of those calls sat inside a pcall, so when the
-- executor errored or truncated the walk the failure was completely silent and
-- the carrier just came back nil. Rigs are Models, so walking Folder children
-- only keeps the cost proportional to the folder layout instead of to the
-- hundreds of thousands of instances in the scene.
local function eachSubFolder(root, maxDepth, fn)
    if not root then return end

    local function walk(node, depth)
        if depth > maxDepth then return end
        pcall(function()
            for _, child in ipairs(node:GetChildren()) do
                if child:IsA("Folder") then
                    fn(child)
                    walk(child, depth + 1)
                end
            end
        end)
    end

    walk(root, 0)
end

-- Every character model under `charsFolder`, alive or not. Rigs sit directly
-- under Characters or inside a per-team Folder, so both are visited; Models
-- inside Models (a rig's own sub-models) are never treated as players.
local function eachCharacter(charsFolder, fn)
    if not charsFolder then return end

    local function consider(inst)
        if inst and inst:IsA("Model") and isCharacterModel(inst) then
            fn(inst)
        end
    end

    pcall(function()
        for _, child in ipairs(charsFolder:GetChildren()) do
            consider(child)
        end
    end)

    eachSubFolder(charsFolder, 3, function(f)
        pcall(function()
            for _, child in ipairs(f:GetChildren()) do
                consider(child)
            end
        end)
    end)
end

-- Every character model under `charsFolder`, keyed by lowercased name, with its
-- liveness. Dead rigs are kept in this table on purpose: the difference between
-- "this player is dead and dropped the bomb" and "this player's rig was not
-- found" decides whether the bomb counts as carried, and collapsing the two is
-- exactly the bug that reported a corpse as the carrier.
local function buildCharacterTable()
    local map = {}

    eachCharacter(Workspace:FindFirstChild("Characters"), function(inst)
        local name = tostring(inst.Name)
        if name ~= "" then
            map[name:lower()] = { model = inst, alive = isAlive(inst) }
        end
    end)

    return map
end

-- Live character models only. Kept for callers that just need the rig itself.
local function buildCharacterMap()
    local map = {}

    eachCharacter(Workspace:FindFirstChild("Characters"), function(inst)
        if not isAlive(inst) then return end
        local name = tostring(inst.Name)
        if name ~= "" then map[name:lower()] = inst end
    end)

    return map
end

-- Independent liveness check that does not depend on the rig at all. Used as a
-- fallback when the character model cannot be located, so a rig change can never
-- silently downgrade "Carrier" to "Dropped".
local function playerLooksPresent(name)
    if type(name) ~= "string" or name == "" then return false end
    local ok, player = pcall(function() return Players:FindFirstChild(name) end)
    return ok and player ~= nil
end

-- The bomb is tracked by IDENTITY, not by name.
--
-- The game moves the SAME BombHolster instance between the carrier's attachment
-- folder and the world when it is dropped or planted. A name search therefore
-- has a blind spot: if the model is renamed on the way out (which is exactly
-- what happened - the bomb went from "found while carried" to "not found at all
-- once dropped", with the same single BombHolster in the scene), every name-based
-- lookup fails. Remembering the instance keeps the bomb tracked across that
-- transition for free.
local stickyHolster = nil

local function rememberHolster(inst)
    if inst then stickyHolster = inst end
end

local function forgetHolster(inst)
    -- Only drop the reference when THIS instance is gone. A different bomb (a
    -- new round) must not be remembered, and a destroyed one must be.
    if (not inst) or (inst == stickyHolster) then
        if (not inst) or (not inst.Parent) then stickyHolster = nil end
    end
end

-- Structural signature for the bomb, used only when the name lookup and the
-- remembered instance both come up empty. The C4 is the only thing in the game
-- with a part named "FlashingLight" (the dump has four occurrences: two in
-- ReplicatedStorage/Database, two in the live holster), so inside Workspace it
-- identifies the bomb regardless of what the model ends up being called.
local function looksLikeBombStructurally(node)
    if not node or (not node:IsA("Model")) then return false end

    local hit = false
    pcall(function()
        for _, d in ipairs(node:GetDescendants()) do
            if d.Name == "FlashingLight" then
                hit = true
                return
            end
        end
    end)
    return hit
end

-- Resolve the bomb and, if it is being carried, by whom.
--
-- Returns: holster, holderName, holderCharacter, source
--
-- holderName is only returned when the bomb is genuinely being carried RIGHT
-- NOW. A corpse keeps its "<Name>_WeaponAttachments" folder, so the folder name
-- alone is not proof of carriage: if the named owner is dead (or has left) the
-- bomb has been dropped and is reported as loose.
--
-- `source` is one of: "carried", "rig", "sticky", "name", "shape" - reported in
-- the on-screen readout so a miss can be attributed to a specific branch.
local function scanForBomb()
    local charsFolder = Workspace:FindFirstChild("Characters")
    local roster = buildCharacterTable()

    -- 1. A BombHolster inside a <Name>_WeaponAttachments folder.
    --
    --    Those folders are siblings of the character models (sometimes inside a
    --    per-team Folder). Every rig ALSO has a plain "WeaponAttachments" folder
    --    of its own, and those never hold the bomb, so only the "<Name>_"
    --    prefixed ones can produce a hit.
    --
    --    Candidates are scored rather than taken first-come, because folder
    --    order is arbitrary and a leftover attachment folder must never beat the
    --    actual carrier.
    if charsFolder then
        local bestHolster, bestOwner, bestChar, bestScore

        eachSubFolder(charsFolder, 4, function(f)
            if bestHolster then return end
            if not isWeaponAttachmentsName(f.Name) then return end

            local owner = ownerNameFromAttachment(f.Name)
            if not owner then return end

            local holster = findHolsterUnder(f)
            if not holster then return end

            -- A resolved, living rig is the strongest evidence of carriage.
            -- A name matching a live Player whose rig was not found is still
            -- good enough: the marker is drawn on the bomb itself, so the
            -- carrier does not have to be located in order to be reported.
            --
            -- A rig that WAS found but is dead scores lowest, even though the
            -- Player row is still present in Players - that is a corpse, not a
            -- carrier. Without this distinction a dead carrier kept being
            -- reported as carrying the bomb.
            local entry = roster[owner:lower()]
            local score
            if entry then
                if entry.alive then
                    score = 3
                else
                    score = 0
                end
            elseif playerLooksPresent(owner) then
                score = 2
            else
                score = 1
            end

            if (not bestScore) or (score > bestScore) then
                bestScore = score
                bestHolster = holster
                bestOwner = owner
                bestChar = entry and entry.alive and entry.model or nil
            end
        end)

        -- Only a living owner counts as "carried". Score 1 means the folder is
        -- left over from a corpse or a despawned player, so the bomb has been
        -- dropped and falls through to be treated as loose.
        if bestHolster and (bestScore >= 2) then
            rememberHolster(bestHolster)
            return bestHolster, bestOwner, bestChar, "carried"
        end
    end

    -- 2. A bomb welded directly to a living character (some builds place it
    --    this way, inside the rig's own WeaponAttachments folder).
    local welded = nil
    local weldedName = nil
    local weldedChar = nil

    eachCharacter(charsFolder, function(char)
        if welded then return end
        if not isAlive(char) then return end
        local holster = nil
        pcall(function() holster = findHolsterUnder(char) end)
        if holster then
            welded = holster
            weldedName = tostring(char.Name)
            weldedChar = char
        end
    end)

    if welded then
        rememberHolster(welded)
        return welded, weldedName, weldedChar, "rig"
    end

    -- 3. The instance we already know about, still parented somewhere. This is
    --    what keeps a dropped or planted bomb visible even if it is renamed or
    --    moved into a corner of the map the scans never visit.
    forgetHolster(stickyHolster)
    if stickyHolster and stickyHolster.Parent then
        return stickyHolster, nil, nil, "sticky"
    end

    -- 4. Loose in the world, matched by name.
    local best = nil

    local function scanByName(node, depth)
        if best or (depth > 5) then return end
        pcall(function()
            if node:IsA("Model") and isBombName(node.Name) then
                best = node
                return
            end
            for _, child in ipairs(node:GetChildren()) do
                scanByName(child, depth + 1)
                if best then return end
            end
        end)
    end

    pcall(function()
        for _, child in ipairs(Workspace:GetChildren()) do
            scanByName(child, 0)
            if best then return end
        end
    end)

    if best then
        rememberHolster(best)
        return best, nil, nil, "name"
    end

    -- 5. Last resort: identify it by shape instead of by name.
    pcall(function()
        for _, child in ipairs(Workspace:GetChildren()) do
            if looksLikeBombStructurally(child) then
                best = child
                return
            end
        end
    end)

    if best then
        rememberHolster(best)
        return best, nil, nil, "shape"
    end

    return nil, nil, nil, "none"
end

-- ==========================================================
-- Planted state
-- ==========================================================
-- An instance dump of a live round shows there are NO bomb attributes anywhere:
-- no @BombPlanted and no @BombTimer. The game reports the plant through a
-- RemoteEvent instead ("Planted", sitting next to BombSiteEntered /
-- BombSiteExited in NetworkRemotes). The previous version polled attributes that
-- do not exist, so "Planted" could never be shown.
--
-- The remote is watched directly and the result is LATCHED: the game fires
-- "Planted" once, so a bare event flag would be gone by the next frame. The
-- latch is released as soon as the bomb is carried again (picked back up) or
-- when the bomb instance goes missing for a whole scan interval (round over).
local plantedState = {
    latched = false,
    latchedAt = nil,
    hookInstalled = false,
    lastSeenBomb = nil,
    missingSince = nil,
}

local function releasePlanted()
    plantedState.latched = false
    plantedState.latchedAt = nil
    plantedState.lastSeenBomb = nil
    plantedState.missingSince = nil
end

local function installPlantedHook()
    if plantedState.hookInstalled then return end

    pcall(function()
        local roots = {
            ReplicatedStorage:FindFirstChild("NetworkRemotes"),
            ReplicatedStorage:FindFirstChild("Remotes"),
            ReplicatedStorage,
        }
        for _, root in ipairs(roots) do
            if root then
                local ev = nil
                pcall(function() ev = root:FindFirstChild("Planted") end)
                if (not ev) or (not ev:IsA("RemoteEvent")) then
                    ev = nil
                    pcall(function()
                        for _, d in ipairs(root:GetDescendants()) do
                            if d.Name == "Planted" and d:IsA("RemoteEvent") then
                                ev = d
                                break
                            end
                        end
                    end)
                end
                if ev then
                    ev.OnClientEvent:Connect(function()
                        plantedState.latched = true
                        plantedState.latchedAt = os.clock()
                    end)
                    plantedState.hookInstalled = true
                    return
                end
            end
        end
    end)
end

-- Returns: planted, timerSeconds
local function plantedInfo(bombInstance)
    if not bombInstance then
        releasePlanted()
        return false, 0
    end

    installPlantedHook()

    -- A different holster instance means a new round, so an old latch is stale.
    if plantedState.lastSeenBomb ~= bombInstance then
        plantedState.latched = false
        plantedState.latchedAt = nil
        plantedState.lastSeenBomb = bombInstance
    end
    plantedState.missingSince = nil

    -- Attributes, in case a future build exposes them. Cheap and harmless.
    local attrPlanted = false
    pcall(function()
        if LocalPlayer:GetAttribute("BombPlanted") == true then attrPlanted = true end
    end)
    pcall(function()
        local char = LocalPlayer.Character
        if char and char:GetAttribute("BombPlanted") == true then attrPlanted = true end
    end)

    local timer = 0
    pcall(function() timer = tonumber(LocalPlayer:GetAttribute("BombTimer")) or 0 end)
    if timer <= 0 then
        pcall(function()
            local char = LocalPlayer.Character
            if char then timer = tonumber(char:GetAttribute("BombTimer")) or 0 end
        end)
    end

    local planted = plantedState.latched or attrPlanted
    if not planted then return false, timer end

    -- No timer value from the game: approximate one from the latch moment.
    if timer <= 0 and plantedState.latchedAt then
        timer = math.max(0, 40 - (os.clock() - plantedState.latchedAt))
    end

    return true, timer
end

-- Somebody picked the bomb back up, so any plant latch has to go.
local function clearPlantedOnCarry()
    if plantedState.latched then releasePlanted() end
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

-- Project a world position onto the screen. When the point is off screen, or
-- behind the camera, the result is where the bearing from the screen centre
-- crosses a box inset from the edges - so the marker always sits ON the screen
-- edge pointing at the bomb, and never in the middle of the view.
--
-- The previous implementation had two defects:
--   * it hid the marker entirely whenever Z <= 0, so a bomb behind the player
--     produced nothing at all;
--   * for the off-screen case it scaled dx and dy independently onto an inset
--     box, which slides the marker to the screen centre as soon as one axis
--     dominates. That is exactly the "floating in empty space" marker.
local function edgeMarker(screenX, screenY, behind, viewport)
    local cx = viewport.X / 2
    local cy = viewport.Y / 2

    local dx = screenX - cx
    local dy = screenY - cy

    -- WorldToViewportPoint mirrors the projection for points behind the camera,
    -- so the true bearing is the negation of the projected one.
    if behind then
        dx = -dx
        dy = -dy
    end

    -- Exactly on the screen centre: any direction is arbitrary, but dx = dy = 0
    -- would leave the marker dead centre, so aim straight up instead.
    if (math.abs(dx) < 0.5) and (math.abs(dy) < 0.5) then
        dx, dy = 0, -1
    end

    -- Inset so the marker is never clipped by the window border.
    local inset = 70
    local maxX = (viewport.X / 2) - inset
    local maxY = (viewport.Y / 2) - inset
    if maxX < 10 then maxX = 10 end
    if maxY < 10 then maxY = 10 end

    -- Intersect the ray with the inset rectangle. Taking the tighter of the two
    -- ratios lands exactly on the nearer edge instead of overshooting it.
    local scale = math.huge
    if math.abs(dx) > 1e-6 then scale = math.min(scale, maxX / math.abs(dx)) end
    if math.abs(dy) > 1e-6 then scale = math.min(scale, maxY / math.abs(dy)) end
    if scale == math.huge then scale = 1 end

    local ax = cx + (dx * scale)
    local ay = cy + (dy * scale)

    -- Hard clamp, so the result is inside the viewport under any input.
    ax = math.max(inset, math.min(viewport.X - inset, ax))
    ay = math.max(inset, math.min(viewport.Y - inset, ay))

    -- Unit bearing, used to orient the arrow so the marker clearly points away
    -- from the player rather than looking like an object hovering in the world.
    local len = math.sqrt((dx * dx) + (dy * dy))
    if len < 1e-6 then
        return ax, ay, 0, -1
    end
    return ax, ay, dx / len, dy / len
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

    if (not okScreen) or (not screen) then
        stateLog("draw failed - WorldToViewportPoint errored on '" .. tostring(inst.Name) .. "'")
        hideItem("World")
        return
    end

    -- Fixed pixel size, same as the GrenadeESP module. Feeding world-space size
    -- straight into pixel dimensions collapses the box to ~2px (invisible) as
    -- soon as the bomb is more than a few studs away. A constant keeps the
    -- marker readable at any distance.
    local width = 26

    local viewport = camera.ViewportSize

    -- Z is the distance along the camera's forward axis, so a negative Z means
    -- the bomb is behind the player. That counts as off screen too, otherwise
    -- turning away from a planted bomb would hide the marker completely.
    local behind = (screen.Z <= 0)

    if behind or (screen.X < 0) or (screen.Y < 0)
        or (screen.X > viewport.X) or (screen.Y > viewport.Y) then
        local ax, ay, ux, uy = edgeMarker(screen.X, screen.Y, behind, viewport)
        local dist = math.floor(math.abs(screen.Z))

        pcall(function()
            -- A triangle pointing outward along the bearing. A plain square here
            -- reads as a world object sitting in mid air, which is what made the
            -- old marker look broken.
            local reach = 12   -- arrow length
            local halfWidth = 9

            local tipX = ax + (ux * reach)
            local tipY = ay + (uy * reach)
            local backX = ax - (ux * reach)
            local backY = ay - (uy * reach)
            local px = -uy
            local py = ux

            if item.Arrow then
                item.Arrow.PointA = Vector2.new(backX + (px * halfWidth), backY + (py * halfWidth))
                item.Arrow.PointB = Vector2.new(tipX, tipY)
                item.Arrow.PointC = Vector2.new(backX - (px * halfWidth), backY - (py * halfWidth))
                item.Arrow.Filled = true
                item.Arrow.Transparency = 0.15
                item.Arrow.Thickness = 2
                item.Arrow.Outline = true
                item.Arrow.Color = color
                item.Arrow.Visible = true
                item.Arrow.ZIndex = 50
            end

            item.Box.Visible = false

            -- Label goes beside the arrow on a side edge, and above it otherwise,
            -- then gets pulled back inside the viewport so it is never clipped.
            local lx, ly = ax, ay
            if math.abs(ux) > math.abs(uy) then
                lx = ax + (ux * 38)
            else
                ly = ay + (uy * 34)
            end
            lx = math.max(46, math.min(viewport.X - 46, lx))
            ly = math.max(14, math.min(viewport.Y - 10, ly))

            item.Label.Text = string.format("%s  %dm", tostring(label), dist)
            item.Label.Size = 18
            item.Label.Outline = true
            item.Label.Center = true
            item.Label.Position = Vector2.new(lx, ly)
            item.Label.Color = color
            item.Label.ZIndex = 51
            item.Label.Visible = true
        end)

        stateLog("bomb off screen - edge marker at ("
            .. tostring(math.floor(ax)) .. ", " .. tostring(math.floor(ay))
            .. ") dist=" .. tostring(dist) .. "m"
            .. (behind and " BEHIND" or ""))
        return
    end

    local okDraw = pcall(function()
        if item.Arrow then item.Arrow.Visible = false end

        item.Box.Position = Vector2.new(screen.X - (width / 2), screen.Y - (width / 2))
        item.Box.Size = Vector2.new(width, width)
        item.Box.Thickness = 1.5
        item.Box.Filled = false
        item.Box.Transparency = 0
        item.Box.ZIndex = 2
        item.Box.Color = color
        item.Box.Visible = true

        item.Label.Text = label
        item.Label.Size = 17
        item.Label.Outline = false
        item.Label.Center = true
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
    bombSource = "none",
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

        local holster, ownerName, char, source = scanForBomb()
        cache.worldBomb = holster
        cache.carrierName = ownerName
        cache.carrier = char
        cache.bombSource = source or "none"

        -- Carrying beats planting: if somebody has the bomb in hand it cannot be
        -- planted, so any plant latch is released here.
        if ownerName then clearPlantedOnCarry() end
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

    local planted, timer = plantedInfo(worldBomb)

    -- On-screen debug readout (top-left, yellow) so the state is visible even
    -- when every console is blocked.
    ensureDebugLabel()
    pcall(function()
        if debugText then
            debugText.Visible = true
            -- Also report whether the bomb is on screen, clamped to an edge, or
            -- behind the camera, because that is the single most useful thing
            -- when the marker looks wrong.
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
                        if sp.Z <= 0 then
                            where = "BEHIND CAMERA (edge arrow)"
                        elseif sp.X < 0 or sp.Y < 0 or sp.X > vs.X or sp.Y > vs.Y then
                            where = "OFF-SCREEN (edge arrow)"
                        else
                            where = string.format("on screen (%.0f,%.0f)", sp.X, sp.Y)
                        end
                    end
                end
            end
            debugText.Text = string.format(
                "C4 ESP  carrier=%s\nbomb=%s\nvia=%s  planted=%s\nstatus=%s",
                tostring(carrierName) or "nil",
                tostring(worldBomb and worldBomb.Name) or "nil",
                tostring(cache.bombSource) or "none",
                tostring(planted),
                where
            )
        end
    end)

    if worldBomb then
        -- One rule decides the label, using the same scan that located the bomb:
        --
        --   carried by a LIVING player  -> C4 Carrier: <name>  (red)
        --   the game fired "Planted"    -> C4 Planted  <t>s     (amber)
        --   anything else               -> C4 Dropped            (green)
        --
        -- "Anything else" covers all three drop cases the game produces: the
        -- carrier dying, the carrier throwing it, and a mid-plant re-drop.
        -- scanForBomb only returns a carrier name when the named owner is still
        -- alive, so a corpse's leftover attachment folder reports as Dropped
        -- instead of keeping the label stuck on "Carrier".
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
