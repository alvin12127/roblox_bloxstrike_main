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

-- ==========================================================
-- Finding the bomb and its carrier
-- ==========================================================
-- Everything here deliberately avoids assuming where things live. An earlier
-- version looked for the attachment folder under Workspace:FindFirstChild
-- ("Characters") and then required the character MODEL to be found and alive
-- before it would name a carrier. In game that path silently did nothing - the
-- readout showed "carrier=nil" with "via=sticky" while somebody was visibly
-- holding the C4, which is the same thing as "branch 1 never fires".
--
-- The robust facts, taken from an instance dump of a live round:
--
--   Workspace
--     Characters                            (Folder, level 1)
--       Terrorists / Counter-Terrorists ...  (Folder, level 2)
--       <Player>                             (Model,  level 2)  <- the rig
--       <Player>_WeaponAttachments           (Folder, level 2)  <- the bomb rig
--         <Player>_Weapon / T Knife / Interactables / BombHolster
--
-- The one relationship that never changes is the one that matters: the rig and
-- the attachment folder are SIBLINGS. So the rig is looked up as a sibling of
-- the folder we already found, and no global anchor, attribute check or Humanoid
-- lookup is needed to reach it.

local function isAlive(char)
    if not char then return false end

    -- The rigs expose @Dead / @Health. There is no Humanoid on a character model
    -- at all, so the attribute is the only reliable signal; the Humanoid branch
    -- is only a fallback for a build that adds one.
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

    -- No liveness information at all: assume alive. Reporting "Dropped" for a
    -- bomb somebody is plainly holding is the worse failure.
    return true
end

local function ownerNameFromAttachment(name)
    if type(name) ~= "string" then return nil end
    return name:match("^(.-)_WeaponAttachments$")
        or name:match("^(.-)%.WeaponAttachments$")
        or name:match("^(.-)_WeaponAttachment$")
end

-- Visit every FOLDER under `root`, up to `maxDepth`, without ever descending
-- into a Model.
--
-- This is the single most important helper in the file. Walking the whole
-- Characters subtree with GetDescendants() visits a dozen rigs of several
-- hundred BaseParts each, and every one of those calls sat inside a pcall - so
-- when the executor errored or truncated the walk the failure was completely
-- silent and the carrier just came back nil. Rigs are Models, so a Folder-only
-- walk keeps the cost proportional to the folder layout instead of to the
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

-- Locate the rig that belongs to an attachment folder.
--
-- Two layouts exist in the wild and which one is live has changed between game
-- versions, so both are handled and neither is assumed:
--
--   Characters
--     <Player>                       <- rig and folder are SIBLINGS
--     <Player>_WeaponAttachments
--
--   Characters
--     Terrorists
--       <Player>                     <- rig one level down, inside a team folder
--     <Player>_WeaponAttachments
--
-- The sibling case is tried first because it is a single shallow call; the
-- folder-only descent is the fallback and costs almost nothing because it never
-- enters a Model.
local function findRigNearAttachment(folder, owner)
    if not folder then return nil end
    local target = tostring(owner):lower()

    local parent = nil
    pcall(function() parent = folder.Parent end)

    if parent then
        -- Assigned to an upvalue, not returned: a `return` inside pcall only
        -- exits the anonymous function and the value is silently lost. That
        -- exact mistake is what made the carrier resolve to nil in game.
        local sibling = nil
        pcall(function()
            for _, sib in ipairs(parent:GetChildren()) do
                if sib:IsA("Model") and (tostring(sib.Name):lower() == target) then
                    sibling = sib
                    break
                end
            end
        end)
        if sibling then return sibling end
    end

    local deep = nil
    eachSubFolder(parent, 3, function(f)
        if deep then return end
        pcall(function()
            for _, child in ipairs(f:GetChildren()) do
                if child:IsA("Model") and (tostring(child.Name):lower() == target) then
                    deep = child
                    return
                end
            end
        end)
    end)

    return deep
end

-- Independent liveness check that does not depend on a rig being locatable at
-- all. Used as a fallback, never as the primary signal.
local function playerLooksPresent(name)
    if type(name) ~= "string" or name == "" then return false end
    local ok, player = pcall(function() return Players:FindFirstChild(name) end)
    return ok and player ~= nil
end

-- The bomb is tracked by IDENTITY, not by name.
--
-- The game replaces the holster when the bomb is dropped or planted - a dropped
-- bomb was never found by name at all, and it was not the carried instance
-- either, since that one had been destroyed. Remembering the instance still
-- covers the common case of a plain reparent; the shape search below is what
-- covers the replacement.
local stickyHolster = nil
local lastOwner = nil

local function rememberHolster(inst, owner)
    if inst then
        stickyHolster = inst
        lastOwner = owner
    end
end

-- Structural signature for the C4. The dump has four occurrences of a part
-- named "FlashingLight" in the entire game: two inside
-- ReplicatedStorage/Database (weapon templates, which this never walks) and two
-- in the live holster. Inside Workspace it therefore identifies the bomb
-- whatever the model ends up being called, which is essential because the name
-- changes the moment it leaves the carrier's hands.
--
-- Returns the bomb model: the nearest enclosing Model whose PrimaryPart is
-- "Body", else the FlashingLight's own parent Model.
local function findBombByShape(root, maxDepth)
    if not root then return nil end

    local found = nil

    local function climb(startNode)
        local m = startNode.Parent
        local guard = 0
        local fallback = nil
        while m and (m ~= root) and (guard < 5) do
            if m:IsA("Model") then
                if not fallback then fallback = m end
                local pp = nil
                pcall(function() pp = m.PrimaryPart end)
                if pp and tostring(pp.Name) == "Body" then return m end
            end
            m = m.Parent
            guard = guard + 1
        end
        return fallback
    end

    local function walk(node, depth)
        if found or (depth > maxDepth) then return end
        pcall(function()
            if node.Name == "FlashingLight" then
                found = climb(node) or node.Parent
                return
            end
            for _, child in ipairs(node:GetChildren()) do
                walk(child, depth + 1)
                if found then return end
            end
        end)
    end

    -- Shallowest Workspace child that contains the signature wins, so a bomb in
    -- the map beats a bomb inside a duplicated template further down.
    pcall(function()
        for _, child in ipairs(root:GetChildren()) do
            walk(child, 0)
            if found then return end
        end
    end)

    return found
end

-- Diagnostics. The previous version reported only "carrier=nil", which cannot
-- distinguish "the attachment folder was never found" from "the folder was found
-- but its owner was rejected". That ambiguity is exactly what left the carried
-- state broken for several rounds.
local probe = {
    attachmentFolders = 0,
    holstersInFolders = 0,
    lastOwner = nil,
    lastOwnerRig = 0,
    lastOwnerAlive = 0,
    lastOwnerPlayer = 0,
    lastScore = 0,
    stickyAlive = 0,
    zoneCount = 0,
    screenTimer = nil,
}

-- Resolve the bomb and, if it is being carried, by whom.
--
-- Returns: holster, holderName, holderCharacter, source
--
-- holderName is only returned when the bomb is genuinely being carried RIGHT
-- NOW. A corpse keeps its "<Name>_WeaponAttachments" folder, so the folder name
-- alone is not proof of carriage: if the named owner is dead the bomb has been
-- dropped and is reported as loose.
local function scanForBomb()
    probe.attachmentFolders = 0
    probe.holstersInFolders = 0

    -- 1. A BombHolster inside a "<Name>_WeaponAttachments" folder.
    --
    --    The walk starts at Workspace, not at Characters: the folder's exact
    --    ancestor has changed between game versions and getting that wrong made
    --    this branch a silent no-op.
    --
    --    Candidates are scored rather than taken first-come, because folder
    --    order is arbitrary and a leftover attachment folder must never beat the
    --    actual carrier.
    local bestHolster, bestOwner, bestChar, bestScore

    eachSubFolder(Workspace, 3, function(f)
        if bestHolster then return end
        if not isWeaponAttachmentsName(f.Name) then return end

        local owner = ownerNameFromAttachment(f.Name)
        if not owner then return end

        probe.attachmentFolders = probe.attachmentFolders + 1

        local holster = findHolsterUnder(f)
        if not holster then return end

        probe.holstersInFolders = probe.holstersInFolders + 1

        -- The rig is a sibling of the attachment folder, or one level below it inside a
        -- per-team Folder. Both layouts are handled by findRigNearAttachment, so
        -- no global anchor and no Humanoid / @CharacterName lookup is needed.
        local rig = findRigNearAttachment(f, owner)

        -- NOTE: written the long way on purpose. `rig and isAlive(rig) or nil`
        -- turns a FALSE into nil, which then falls through to the Player check
        -- and reports a dead body as the carrier - the exact bug this replaced.
        local alive = nil
        if rig then alive = isAlive(rig) end

        -- Score, highest wins:
        --   3  rig found and alive                      -> carried
        --   2  no rig found, but a Player row exists    -> carried
        --   0  rig found and DEAD                       -> dropped
        --   1  nothing known                            -> dropped
        --
        -- Score 0 matters because a dead player keeps their row in Players, so
        -- the Player fallback on its own would keep calling a corpse the carrier.
        local score
        if alive == true then
            score = 3
        elseif alive == false then
            score = 0
        elseif playerLooksPresent(owner) then
            score = 2
        else
            score = 1
        end

        if (not bestScore) or (score > bestScore) then
            bestScore = score
            bestHolster = holster
            bestOwner = owner
            bestChar = rig
        end
    end)

    probe.lastOwner = bestOwner
    probe.lastScore = bestScore or -1
    probe.lastOwnerRig = bestChar and 1 or 0
    probe.lastOwnerAlive = (bestChar and isAlive(bestChar)) and 1 or 0
    probe.lastOwnerPlayer = (bestOwner and playerLooksPresent(bestOwner)) and 1 or 0

    if bestHolster then
        rememberHolster(bestHolster, bestOwner)
        -- Only a living owner counts as "carried". A dead or unknown owner means
        -- the folder is left over and the bomb has been dropped.
        if bestScore >= 2 then
            return bestHolster, bestOwner, bestChar, "carried"
        end
    end

    -- 2. The instance we already know about, still parented somewhere. This
    --    covers a plain reparent, including a rename.
    if stickyHolster and stickyHolster.Parent then
        probe.stickyAlive = 1
        return stickyHolster, nil, nil, "sticky"
    end
    stickyHolster = nil

    -- 3. Name match. Kept, but demoted: the name is not stable across a drop.
    local byName = nil

    local function scanByName(node, depth)
        if byName or (depth > 5) then return end
        pcall(function()
            if node:IsA("Model") and isBombName(node.Name) then
                byName = node
                return
            end
            for _, child in ipairs(node:GetChildren()) do
                scanByName(child, depth + 1)
                if byName then return end
            end
        end)
    end

    pcall(function()
        for _, child in ipairs(Workspace:GetChildren()) do
            scanByName(child, 0)
            if byName then return end
        end
    end)

    if byName then
        rememberHolster(byName, nil)
        return byName, nil, nil, "name"
    end

    -- 4. Shape match. This is what actually finds a dropped or planted bomb,
    --    because by then the model has been replaced and renamed.
    local byShape = findBombByShape(Workspace, 6)
    if byShape then
        rememberHolster(byShape, nil)
        return byShape, nil, nil, "shape"
    end

    return nil, nil, nil, "none"
end

-- ==========================================================
-- Planted state
-- ==========================================================
-- There are NO bomb attributes in this game. An instance dump of a live round has
-- zero @BombPlanted and zero @BombTimer, so the previous version polled values
-- that do not exist and "Planted" was structurally unreachable.
--
-- What is actually available, all confirmed from the dump:
--
--   ReplicatedStorage/NetworkRemotes/C4/Planted        (RemoteEvent)
--   ReplicatedStorage/NetworkRemotes/C4/Defused        (RemoteEvent)
--   ReplicatedStorage/NetworkRemotes/C4/Cancel        (RemoteEvent)
--   ReplicatedStorage/NetworkRemotes/C4/ForceCancel   (RemoteEvent)
--   Workspace.../<Sites>/ZoneParts_A/B  -> Parts with @Site = "A" / "B"
--   the bomb's Screen -> SurfaceGui -> TextLabel, which shows the countdown
--
-- Three independent signals are used, in order of confidence:
--
--   1. the C4 remote fired              -> planted, exact
--   2. the Screen reads a countdown     -> planted, and it gives the timer
--   3. the bomb sits inside a bomb site -> planted, inferred
--
-- The latch is the subtle part. Planting REPLACES the holster, so clearing the
-- latch when the bomb instance changes wiped it on the very frame the plant
-- arrived - which is exactly why a planted bomb was reported as "Dropped".
-- The instance identity is therefore no longer used to decide a new round; the
-- latch is released only when the bomb disappears for a while, when somebody
-- carries it again, or when the game says the plant ended.
-- The fuse length. Configured rather than hard-coded because the instance dump
-- exposes no bomb timer constant anywhere; 40s is the value this map is expected
-- to use. The countdown is measured from when the ESP first sees the plant, so
-- the displayed value starts within one scan interval of the real one and then
-- decreases on its own, every frame, with no input from the game.
local DEFAULT_BOMB_TIME = 40
local ROUND_RESET_GRACE = 1.5

local function bombTime()
    local configured = nil
    pcall(function() configured = tonumber(storedConfig and storedConfig.C4_BOMB_TIME) end)
    if configured and configured > 0 and configured < 600 then return configured end
    return DEFAULT_BOMB_TIME
end

local plantedState = {
    latched = false,
    latchedAt = nil,
    hookInstalled = false,
    missingSince = nil,
    -- When the countdown started for the bomb currently on the ground. Anchored
    -- here rather than read from the game, because every game-provided value was
    -- measured to be wrong: the Screen reads 67 for a planted bomb AND for a
    -- dropped one, and there is no @BombTimer attribute to read.
    countdownSince = nil,
    countdownBomb = nil,
}

local function releasePlanted()
    plantedState.latched = false
    plantedState.latchedAt = nil
    plantedState.missingSince = nil
    plantedState.countdownSince = nil
    plantedState.countdownBomb = nil
end

-- The remotes live at ReplicatedStorage/NetworkRemotes/C4/<name>. Three
    -- fallback layouts are tried as well, because a remote moving one folder up
    -- would otherwise make "Planted" silently unreachable again - which is
    -- exactly how this feature failed in the first place.
local function locateC4Remote(name)
    local remotes = nil
    pcall(function() remotes = ReplicatedStorage:FindFirstChild("NetworkRemotes") end)

    local c4 = nil
    if remotes then
        pcall(function() c4 = remotes:FindFirstChild("C4") end)
    end
    if not c4 then
        pcall(function()
            for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
                if d:IsA("Folder") and d.Name == "C4" then c4 = d break end
            end
        end)
    end

    local function pick(container)
        local ev = nil
        if container then
            pcall(function() ev = container:FindFirstChild(name) end)
        end
        if ev and ev:IsA("RemoteEvent") then return ev end
        return nil
    end

    return pick(c4) or pick(remotes)
        or (function()
            local found = nil
            pcall(function()
                for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
                    if d.Name == name and d:IsA("RemoteEvent") then found = d break end
                end
            end)
            return found
        end)()
end

local function installPlantedHook()
    if plantedState.hookInstalled then return end

    pcall(function()
        local function connect(name, fn)
            local ev = locateC4Remote(name)
            if not ev then return false end
            ev.OnClientEvent:Connect(fn)
            return true
        end

        local hooked = false
        hooked = connect("Planted", function()
            plantedState.latched = true
            plantedState.latchedAt = os.clock()
        end) or hooked

        -- The plant ended: defused, or cancelled. Any of these releases it, so a
        -- stale latch cannot survive into the next round.
        for _, name in ipairs({ "Defused", "ForceCancel", "Cancel" }) do
            hooked = connect(name, function() releasePlanted() end) or hooked
        end

        plantedState.hookInstalled = hooked
    end)
end

-- The C4 has a Screen part with a SurfaceGui whose TextLabel shows the countdown
-- once it is planted. Read at runtime; the instance dump does not record GUI text
-- so this could not be confirmed offline, but it costs nothing to try and it
-- yields the real timer instead of a guess.
--
-- Every TextLabel on the screen is examined and the first one that parses as a
-- clock wins. Taking the first label unconditionally was wrong: the C4 screen
-- carries more than one, and picking a non-numeric one silently yielded nil,
-- which is exactly the "planted=false with no explanation" case.
local function parseClock(text)
    if type(text) ~= "string" then return nil end

    local trimmed = text:match("^%s*(%S+)%s*$")
    if not trimmed then return nil end

    -- "0:38" / "1:05" -> seconds
    local m, s = trimmed:match("^(%d+):(%d%d)$")
    if m then return (tonumber(m) * 60) + tonumber(s) end

    -- Plain digits, with or without a decimal point ("38", "38.4").
    local n = tonumber(trimmed)
    if n then
        if n > 100 then return nil end      -- too large to be a clock
        return n
    end

    return nil
end

local function readScreenTimer(inst)
    if not inst then return nil end

    -- The Screen may sit on the bomb model or on an ancestor of it, so both are
    -- consulted. The shape finder returns the inner "Weapon" model, which is
    -- where the dump shows the Screen living.
    local candidates = { inst }
    local up = nil
    pcall(function() up = inst.Parent end)
    local guard = 0
    while up and guard < 3 do
        table.insert(candidates, up)
        pcall(function() up = up.Parent end)
        guard = guard + 1
    end

    for _, root in ipairs(candidates) do
        local screens = {}
        pcall(function()
            for _, d in ipairs(root:GetDescendants()) do
                if d.Name == "Screen" and d:IsA("BasePart") then
                    table.insert(screens, d)
                end
            end
        end)

        for _, screen in ipairs(screens) do
            local labels = {}
            pcall(function()
                for _, g in ipairs(screen:GetDescendants()) do
                    if g:IsA("TextLabel") then table.insert(labels, g) end
                end
            end)
            for _, g in ipairs(labels) do
                local t = nil
                pcall(function() t = g.Text end)
                local seconds = parseClock(t)
                if seconds then return seconds end
            end
        end
    end

    return nil
end

-- Bomb site zones.
--
-- The real path, from the dump's indentation levels:
--
--   Workspace                             lead 0
--     Map                                 lead 4    <- Model
--       Zones                             lead 8    <- Model
--         Sites                           lead 12   <- Folder
--           ZoneParts_A / ZoneParts_B               (Parts with @Site)
--
-- Two things made the site signal dead. "Sites" is not a direct child of
-- Workspace or ReplicatedStorage, it is three levels down; and "Map" and "Zones"
-- are MODELS, so the folder-only walk used everywhere else stops before reaching
-- it. A search that only descends into Folders cannot find this at all.
local siteZones = nil
local siteBoxes = nil
local siteSearch = { found = 0, nodes = 0, budget = 400 }

-- Locate the "Sites" folder. The known path is tried first because it costs
-- three property reads, then a bounded search so a future map rename still works
-- without letting a whole-map walk stall the frame.
local function locateSitesFolder()
    local known = {
        "Map.Zones.Sites",
        "Map.Sites",
        "Sites",
        "Zones.Sites",
    }
    for _, path in ipairs(known) do
        local node = Workspace
        local ok = true
        for seg in path:gmatch("[^.]+") do
            local nextNode = nil
            pcall(function() nextNode = node:FindFirstChild(seg) end)
            if not nextNode then ok = false break end
            node = nextNode
        end
        if ok and node then return node end
    end

    -- Bounded fallback. Models are followed as well as Folders, and the number of
    -- GetChildren calls is capped so this can never walk the entire map.
    local found = nil
    local function walk(node, depth)
        if found or depth > 6 then return end
        siteSearch.nodes = siteSearch.nodes + 1
        if siteSearch.nodes > siteSearch.budget then return end

        pcall(function()
            for _, child in ipairs(node:GetChildren()) do
                if found then return end
                if child:IsA("Folder") and child.Name == "Sites" then
                    found = child
                    return
                end
                if child:IsA("Folder") or child:IsA("Model") then
                    walk(child, depth + 1)
                end
            end
        end)
    end

    pcall(function() walk(Workspace, 0) end)
    return found
end

local function buildSiteZones()
    if siteZones then return siteZones end
    siteZones = {}

    local sites = locateSitesFolder()
    siteSearch.found = (sites and 1) or 0
    if not sites then return siteZones end

    eachSubFolder(sites, 3, function(zf)
        pcall(function()
            for _, part in ipairs(zf:GetChildren()) do
                if part:IsA("BasePart") then
                    local site = nil
                    pcall(function() site = part:GetAttribute("Site") end)
                    if site then
                        local pos, size = nil, nil
                        pcall(function() pos = part.Position end)
                        pcall(function() size = part.Size end)
                        if pos then
                            table.insert(siteZones, {
                                site = tostring(site),
                                pos = pos,
                                size = size,
                            })
                        end
                    end
                end
            end
        end)
    end)

    return siteZones
end

-- Bomb site boxes.
--
-- The @Site parts are ZonePlus trigger volumes scattered around where a site is,
-- so testing each part individually with a fixed radius is unreliable: a bomb
-- planted on the floor of a site is not within a few studs of any single
-- trigger. The parts sharing a site letter are therefore unioned into one box
-- and padded, which covers the site volume itself.
--
-- This is also the only signal that can mean "planted" by itself, because the
-- bomb cannot be planted anywhere else. The Screen text does NOT qualify:
-- measured in game it reads a number both when the bomb is planted and when it
-- is merely lying on the floor, so using it as a signal reported every drop as a
-- plant.
local SITE_PAD = 45

local function buildSiteBoxes()
    if siteBoxes then return siteBoxes end
    siteBoxes = {}

    for _, z in ipairs(buildSiteZones()) do
        local box = siteBoxes[z.site]
        if not box then
            box = {
                site = z.site,
                minX = math.huge, minY = math.huge, minZ = math.huge,
                maxX = -math.huge, maxY = -math.huge, maxZ = -math.huge,
            }
            siteBoxes[z.site] = box
        end

        local sx, sy, sz = 0, 0, 0
        if z.size then sx, sy, sz = z.size.X, z.size.Y, z.size.Z end
        local hx, hy, hz = sx / 2, sy / 2, sz / 2

        if z.pos.X - hx < box.minX then box.minX = z.pos.X - hx end
        if z.pos.Y - hy < box.minY then box.minY = z.pos.Y - hy end
        if z.pos.Z - hz < box.minZ then box.minZ = z.pos.Z - hz end
        if z.pos.X + hx > box.maxX then box.maxX = z.pos.X + hx end
        if z.pos.Y + hy > box.maxY then box.maxY = z.pos.Y + hy end
        if z.pos.Z + hz > box.maxZ then box.maxZ = z.pos.Z + hz end
    end

    return siteBoxes
end

-- Returns the site letter the bomb is inside, or nil.
local function insideBombSite(position)
    if not position then return nil end

    for _, box in pairs(buildSiteBoxes()) do
        local p = SITE_PAD
        if position.X >= box.minX - p and position.X <= box.maxX + p
            and position.Y >= box.minY - p and position.Y <= box.maxY + p
            and position.Z >= box.minZ - p and position.Z <= box.maxZ + p then
            return box.site
        end
    end
    return nil
end

-- Returns: planted, timerSeconds, siteNameOrNil, signalName
--
-- `signalName` is reported in the readout so a planted=true can always be
-- attributed to the signal that produced it. That distinction mattered: the
-- Screen text was originally treated as proof of a plant, and because it reads a
-- number whether or not the bomb is planted, every drop on the floor was
-- reported as a plant for several rounds with no way to see why.
local function plantedInfo(bombInstance, position)
    -- No bomb at all: after a grace period the round is over and any latch is
    -- stale. The grace period matters because a plant briefly destroys the old
    -- holster, and clearing on that would wipe the latch again.
    if not bombInstance then
        if plantedState.missingSince == nil then
            plantedState.missingSince = os.clock()
        elseif (os.clock() - plantedState.missingSince) > ROUND_RESET_GRACE then
            releasePlanted()
        end
        return false, 0, nil, "none"
    end

    installPlantedHook()
    plantedState.missingSince = nil

    -- The Screen is read for diagnostics ONLY. It is not a countdown: in game it
    -- reads 67 for a planted bomb and 67 for one lying on the floor, which is
    -- neither the fuse length nor a value that decreases. Showing it produced a
    -- nonsensical "Planted 67s" that never moved.
    local screenTimer = readScreenTimer(bombInstance)
    probe.screenTimer = screenTimer

    local zones = buildSiteZones()
    probe.zoneCount = zones and #zones or 0

    -- Decision, in order of confidence:
    --   1. the C4 remote fired          exact
    --   2. the bomb is inside a site    inferred, but a plant is only possible
    --                                    inside a site, so this cannot be a
    --                                    false negative for a real plant
    local site = insideBombSite(position)

    local signal = "none"
    if plantedState.latched then
        signal = "remote"
    elseif site then
        signal = "site"
    end

    if signal == "none" then
        -- Not planted: drop the countdown anchor so the next plant starts fresh.
        plantedState.countdownSince = nil
        plantedState.countdownBomb = nil
        return false, 0, nil, signal
    end

    -- Anchor the countdown the first time this bomb is seen planted, and re-anchor
    -- if the bomb instance itself changes (the plant replaces the holster).
    if plantedState.countdownSince == nil
        or plantedState.countdownBomb ~= bombInstance then
        plantedState.countdownSince = os.clock()
        plantedState.countdownBomb = bombInstance
    end

    local elapsed = os.clock() - plantedState.countdownSince
    local timer = math.max(0, bombTime() - elapsed)

    return true, timer, site, signal
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

    local planted, timer, plantedSite, plantSignal = plantedInfo(worldBomb, resolvePosition(worldBomb, 0))

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
                "C4 carrier=%s bomb=%s\nvia=%s planted=%s sig=%s site=%s\natt=%d hol=%d own=%s zones=%d\nscore=%d rig=%d alive=%d pl=%d stick=%d scr=%s\nstatus=%s",
                tostring(carrierName) or "nil",
                tostring(worldBomb and worldBomb.Name) or "nil",
                tostring(cache.bombSource) or "none",
                tostring(planted),
                tostring(plantSignal) or "none",
                tostring(plantedSite) or "-",
                probe.attachmentFolders,
                probe.holstersInFolders,
                tostring(probe.lastOwner) or "-",
                probe.zoneCount,
                probe.lastScore,
                probe.lastOwnerRig,
                probe.lastOwnerAlive,
                probe.lastOwnerPlayer,
                probe.stickyAlive,
                tostring(probe.screenTimer) or "-",
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
                .. (plantedSite and ("  SITE " .. tostring(plantedSite)) or "")
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
