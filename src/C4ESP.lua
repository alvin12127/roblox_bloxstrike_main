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

-- The C4 rig lives under a folder named after its owner. The dump shows
-- "<Player>_WeaponAttachments", but the suffix has been spelled differently
-- across game versions and the weapon model itself is also named
-- "<Player>_Weapon", so only the "_Weapon" part is treated as fixed. Matching the
-- suffix exactly was one reason the bomb went unfindable the moment the local
-- player picked it up.
--
-- Returns the owner name, or nil if the folder is not an attachment folder.
local function ownerNameFromWeaponFolder(name)
    if type(name) ~= "string" then return nil end
    local lower = name:lower()

    local owner = lower:match("^(.-)_weaponattachments$")
        or lower:match("^(.-)%.weaponattachments$")
        or lower:match("^(.-)_weaponattachment$")
        or lower:match("^(.-)_weapon$")
    if not owner or owner == "" then return nil end

    -- "WeaponAttachments" on its own belongs to a rig, not to a player.
    if owner:find("weapon", 1, true) then return nil end
    return owner
end

local function isBombName(name)
    if type(name) ~= "string" then return false end
    return BOMB_MODEL_NAMES[name:lower()] == true
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
-- The real layout, from an instance dump:
--
--   Workspace
--     Characters                            (Folder)
--       <Player>                             (Model - the rig)
--       <Player>_WeaponAttachments           (Folder)
--         <Player>_Weapon                    (Model)
--           T Knife                          (Model)
--             Interactables                  (Folder)
--               BombHolster                  (Model, PP "Body")
--
-- One pass, one index.
--
-- The previous version walked the folder tree once per candidate, and inside
-- each walk it re-enumerated every folder under Characters looking for the rig.
-- With five attachment folders that is five full re-walks of the same tree -
-- quadratic, and it is why picking the C4 up made the game stutter: the scan
-- runs from the render path and the cost grew with the number of players holding
-- weapons. buildIndex() walks once and records both halves of the answer, so the
-- scan is linear and independent of how many rigs are in the round.
local BOMB_TREE_DEPTH = 5

-- Liveness. The rigs expose @Dead / @Health attributes; there is no Humanoid on
-- a character model at all, so the attribute is the only reliable signal. The
-- Humanoid branch below is kept purely as a fallback for a build that adds one.
--
-- A corpse keeps its attachment folder, so without this the ESP kept reporting a
-- dead body as the carrier and the bomb on the floor was never shown.
local function isAlive(char)
    if not char then return false end

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

-- Visit every FOLDER under `root`, up to `maxDepth`, without ever descending into
-- a Model. Rigs are Models holding several hundred BaseParts each, so a walk that
-- entered them walked hundreds of thousands of instances.
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

-- Find the bomb under `node`. Matched by name OR by shape, because the name is
-- not stable - the game renames or replaces the holster when it changes hands.
--
-- This is a bounded GetChildren walk with an early exit rather than
-- GetDescendants(), which allocates a table covering the whole subtree before
-- the first check even runs.
local function findHolsterUnder(node)
    if not node then return nil end

    local found = nil
    local visited = 0

    local function walk(inst, depth)
        if found or depth > BOMB_TREE_DEPTH then return end
        visited = visited + 1
        if visited > 300 then return end

        pcall(function()
            if inst:IsA("Model") and (isBombName(inst.Name) or inst.Name == "BombHolster") then
                found = inst
                return
            end
            for _, child in ipairs(inst:GetChildren()) do
                walk(child, depth + 1)
                if found then return end
            end
        end)
    end

    pcall(function() walk(node, 0) end)
    return found
end

-- One folder-only pass that records, in a single traversal:
--   index.owners[name] = the "<Player>_Weapon..." folder
--   index.rigs[name]   = the character Model of that name
--
-- Models are indexed only when they are a direct child of a visited folder, so a
-- rig's own sub-models cannot be mistaken for a player.
local function buildIndex()
    local index = { owners = {}, rigs = {} }

    local function consider(inst)
        if inst:IsA("Folder") then
            local owner = ownerNameFromWeaponFolder(inst.Name)
            if owner and (not index.owners[owner]) then
                index.owners[owner] = inst
            end
        elseif inst:IsA("Model") then
            local key = tostring(inst.Name):lower()
            if (not index.rigs[key]) then index.rigs[key] = inst end
        end
    end

    local function walk(node, depth)
        if depth > 4 then return end
        pcall(function()
            for _, child in ipairs(node:GetChildren()) do
                consider(child)
                if child:IsA("Folder") then walk(child, depth + 1) end
            end
        end)
    end

    pcall(function() walk(Workspace, 0) end)
    return index
end

-- The index only changes when someone dies, spawns or picks the bomb up, which
-- is orders of magnitude rarer than the render rate. Rebuilding it every scan
-- interval is what caused the stutter, so it is cached.
--
-- The TTL alone is not enough, and the reason is exactly the reported bug: the
-- moment a player picks the C4 up, a brand new "<Player>_WeaponAttachments"
-- folder appears, and a stale index cannot see it - the bomb stayed unfindable
-- for as long as the cache lived. So the cache is also dropped the moment a scan
-- finds no holster at all, which costs one extra walk and makes the pickup
-- visible on the very next scan.
local indexCache = { value = nil, builtAt = 0 }
local INDEX_TTL = 0.75

local function getIndex()
    local now = os.clock()
    if indexCache.value and ((now - indexCache.builtAt) < INDEX_TTL) then
        return indexCache.value
    end
    indexCache.value = buildIndex()
    indexCache.builtAt = now
    return indexCache.value
end

local function dropIndex()
    indexCache.value = nil
    indexCache.builtAt = 0
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

local function rememberHolster(inst)
    if inst then stickyHolster = inst end
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

-- Resolve the bomb and, if it is being carried, by whom.
--
-- Returns: holster, holderName, holderCharacter
local function scanForBomb()
    local index = getIndex()

    -- 1. A bomb inside a "<Player>_Weapon..." folder.
    --
    --    Candidates are scored rather than taken first-come, because folder order
    --    is arbitrary and a leftover attachment folder must never beat the actual
    --    carrier.
    local bestHolster, bestOwner, bestChar, bestScore

    for owner, folder in pairs(index.owners) do
        local holster = findHolsterUnder(folder)
        if holster then
            local rig = index.rigs[owner:lower()]
            local name = nil
            pcall(function() name = rig and rig.Name end)

            -- NOTE: written the long way on purpose. `rig and isAlive(rig) or nil`
            -- turns a FALSE into nil, which falls through to the Player check and
            -- reports a dead body as the carrier.
            local alive = nil
            if rig then alive = isAlive(rig) end

            -- Score, highest wins:
            --   3  rig found and alive                   -> carried
            --   2  no rig found, but a Player row exists -> carried
            --   0  rig found and DEAD                    -> dropped
            --   1  nothing known                         -> dropped
            --
            -- Score 0 matters because a dead player keeps their row in Players, so
            -- the Player fallback alone would keep calling a corpse the carrier.
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
        end
    end

    if bestHolster then
        rememberHolster(bestHolster)
        -- Only a living owner counts as "carried". A dead or unknown owner means
        -- the folder is left over and the bomb has been dropped.
        if bestScore >= 2 then
            return bestHolster, bestOwner, bestChar
        end
    else
        -- No holster in any attachment folder. Either the bomb is not being
        -- carried, or a carrier just appeared and the index predates it. Drop
        -- the cache so the next scan is not blind to it.
        dropIndex()
    end

    -- 2. The instance we already know about, still parented somewhere. This
    --    covers a plain reparent, including a rename.
    if stickyHolster and stickyHolster.Parent then
        return stickyHolster, nil, nil
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
        rememberHolster(byName)
        return byName, nil, nil
    end

    -- 4. Shape match. This is what actually finds a dropped or planted bomb,
    --    because by then the model has been replaced and renamed.
    local byShape = findBombByShape(Workspace, 6)
    if byShape then
        rememberHolster(byShape)
        return byShape, nil, nil
    end

    return nil, nil, nil
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

-- Node budget for the fallback search below. Without it, a renamed map folder
-- would send the walk across the whole scene from the RenderStepped path.
local SITE_SEARCH_BUDGET = 400

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
    local visited = 0
    local function walk(node, depth)
        if found or depth > 6 then return end
        visited = visited + 1
        if visited > SITE_SEARCH_BUDGET then return end

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
-- This is the only signal that can mean "planted" by itself, because the bomb
-- cannot be planted anywhere else. The Screen text does NOT qualify and its
-- reader was removed: measured in game it read 67 for a planted bomb AND for one
-- lying on the floor, so it drove a frozen "Planted 67s" and then produced
-- false positives for ordinary drops.
--
-- The cost of a site-only test is that a bomb dropped INSIDE a site reads as
-- planted. The padding is therefore kept tight and configurable rather than
-- generous: at 45 studs the box reached most of a bombsite approach, which is
-- what turned plain drops into plants.
local DEFAULT_SITE_PAD = 12

local function sitePad()
    local configured = nil
    pcall(function() configured = tonumber(storedConfig and storedConfig.C4_PLANTED_SITE_PAD) end)
    if configured and configured >= 0 and configured < 200 then return configured end
    return DEFAULT_SITE_PAD
end

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
        local p = sitePad()
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
    if not item then return end

    local position = resolvePosition(inst, 0)

    if not position then
        hideItem("World")
        return
    end

    local okScreen, screen = pcall(camera.WorldToViewportPoint, camera, position)

    if (not okScreen) or (not screen) then
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

        return
    end

    pcall(function()
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

    local planted, timer, plantedSite = plantedInfo(worldBomb, resolvePosition(worldBomb, 0))

    if worldBomb then
        -- One rule decides the label, using the same scan that located the bomb:
        --
        --   carried by a LIVING player  -> C4 Carrier: <name>  (red)
        --   planted                    -> C4 Planted  <t>s     (amber)
        --   anything else              -> C4 Dropped            (green)
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
            if item.Arrow then item.Arrow:Remove() end
        end)
        C4ESP.Items[key] = nil
    end

    cache.worldBomb = nil
    cache.carrierName = nil
    cache.carrier = nil
    cache.worldBombValid = false
    cache.lastBombScan = 0

    -- Planted state is module-level, so it has to be cleared explicitly or a
    -- re-init would inherit a latch from the previous session.
    releasePlanted()
    siteZones = nil
    siteBoxes = nil

    storedConfig = nil
    C4ESP.Initialized = false
end

return C4ESP
