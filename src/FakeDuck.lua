-- Fake duck: keep full walking speed while crouched.
--
-- Two client-side attempts failed, and both failed for the same structural
-- reason, which is worth writing down:
--
--   1. Writing AssemblyLinearVelocity every Heartbeat. The movement simulation
--      re-applies its own cap on every physics step, so the write is corrected
--      before it is ever observed.
--   2. Clearing the rig's @IsCrouching attribute. That attribute is the game's
--      own display flag for the crouch animation - it is set on every character in
--      the dump and nothing else reads it - so the speed penalty is computed from
--      somewhere else entirely.
--
-- The penalty therefore lives inside the movement code, which this client can see
-- and modify: ReplicatedStorage/MovementV2. The instance dump names the modules
-- but does NOT record their source, so no constant can be read offline and any
-- hard-coded field name would be a guess. Instead the tables are inspected at
-- runtime: every numeric field whose name mentions crouch/duck/sneak is raised to
-- the highest plausible speed in the same table. That is self-calibrating - it
-- does not matter what the field is called, and it cannot invent a value that the
-- game did not already use.
--
-- The pose is deliberately left alone. The local player appears to stand and only
-- locally; nothing here touches other players, the rig, the animation or the
-- camera.

local RunService = nil
local ReplicatedStorage = nil

pcall(function()
    RunService = game:GetService("RunService")
    ReplicatedStorage = game:GetService("ReplicatedStorage")
end)

-- Modules that could hold a movement speed. Tried in order; the first ones are
-- the ones named SpeedProfile and Config, which is where a speed table belongs.
-- The rest are harmless to read and cover a future reorganisation.
local CANDIDATE_PATHS = {
    "MovementV2.SpeedProfile",
    "MovementV2.Config",
    "MovementV2.Simulation.Config",
    "MovementV2.RuntimeSettings",
    "MovementV2.Simulation.RuntimeSettings",
    "MovementV2.Mapping",
    "MovementV2.RuntimeKinematics",
    "MovementV2.Simulation.Solver",
    "MovementV2.Simulation.State",
    "MovementV2.Transport",
}

-- A walking or running speed in this game is a small number of studs per second.
-- Anything outside this band is a spring constant, an angle or a timer and must
-- not be used as the value to copy.
local MIN_PLAUSIBLE_SPEED = 6
local MAX_PLAUSIBLE_SPEED = 60

-- A value at or below 1 is a ratio applied to a speed, not a speed. Ducking
-- multipliers live in roughly 0.2 - 0.7 and a real crouch speed is never below a
-- couple of studs per second, so the two never overlap.
local function isFactor(value)
    return type(value) == "number" and value > 0 and value <= 1
end

local CROUCH_WORDS = { crouch = true, duck = true, sneak = true }

local function isCrouchKey(key)
    if type(key) ~= "string" then return false end
    local lower = key:lower()
    for word in pairs(CROUCH_WORDS) do
        if lower:find(word, 1, true) then return true end
    end
    return false
end

-- Split "A.B.C" into { "A", "B", "C" }.
--
-- Written out rather than using string.gmatch inline, because gmatch returns a
-- STATEFUL iterator function and ipairs expects a table: passing one straight
-- through silently yields zero iterations, so every module path resolved to nil and
-- the scan appeared to find nothing while reporting that it had run.
local function split(path)
    local parts = {}
    for segment in tostring(path):gmatch("[^%.]+") do
        parts[#parts + 1] = segment
    end
    return parts
end

local function resolve(segments)
    local node = ReplicatedStorage
    for _, name in ipairs(segments) do
        local child = nil
        pcall(function() child = node:FindFirstChild(name) end)
        if not child then return nil end
        node = child
    end
    return node
end

--------------------------------------------------------------------
-- Patch
--------------------------------------------------------------------
local scanned = false

-- Two lists, because they answer different questions.
--
--   seen    - every crouch-named field the last scan found, whatever its value.
--             This is what proves the scan reached the right table: a field that
--             shows up here with value 1 or the standing speed has been handled.
--   applied - only the fields this code actually changed, cumulative.
--
-- A single list was wrong. The scan runs every 2 seconds and re-applies from
-- scratch, so after the first pass it changed nothing and reported "patched=0",
-- which reads exactly like "found no crouch field at all". The success case and
-- the total-failure case reported the same string.
local seen = {}
local applied = {}
local appliedSet = {}

local function note(list, set, text)
    if set then
        if set[text] then return end
        set[text] = true
    end
    list[#list + 1] = text
end

-- Walk a module table and neutralise every crouch-named field, in the way that
-- matches what the field actually is.
--
-- Two shapes have to be told apart, and conflating them is what an earlier draft
-- did: a crouch SPEED (CrouchSpeed = 7, studs per second) is raised to the fastest
-- standing speed in the same table, while a crouch FACTOR (DuckMultiplier = 0.45,
-- applied to a speed the code gets elsewhere) is set to 1. Writing a speed into a
-- multiplier does not remove the penalty, it multiplies it - the character ends up
-- faster than a sprint, which reads as a hack rather than as fake duck.
local function patchTable(root, depth)
    if depth > 3 then return end

    pcall(function()
        for key, value in pairs(root) do
            if type(value) == "table" then
                patchTable(value, depth + 1)
            end
        end
    end)

    -- Collect this level's numbers first, so the standing reference is known
    -- before anything is written.
    local fastest = nil
    local crouchKeys = {}

    pcall(function()
        for key, value in pairs(root) do
            if type(value) == "number" then
                if value >= MIN_PLAUSIBLE_SPEED and value <= MAX_PLAUSIBLE_SPEED then
                    if (not fastest) or value > fastest then fastest = value end
                end
                if isCrouchKey(key) and value > 0 and value < MAX_PLAUSIBLE_SPEED then
                    crouchKeys[#crouchKeys + 1] = { key = key, value = value }
                end
            end
        end
    end)

    for _, entry in ipairs(crouchKeys) do
        if isFactor(entry.value) then
            note(seen, nil, string.format("%s=x%s", tostring(entry.key), tostring(entry.value)))
            if entry.value ~= 1 then
                local ok = pcall(function() root[entry.key] = 1 end)
                if ok then
                    note(applied, appliedSet, string.format("%s x%s->x1",
                        tostring(entry.key), tostring(entry.value)))
                end
            end
        elseif fastest then
            note(seen, nil, string.format("%s=%s", tostring(entry.key), tostring(entry.value)))
            if entry.value < fastest then
                local ok = pcall(function() root[entry.key] = fastest end)
                if ok then
                    note(applied, appliedSet, string.format("%s %s->%s",
                        tostring(entry.key), tostring(entry.value), tostring(fastest)))
                end
            end
        end
    end
end

-- Repeated on a slow interval because the game can reassign its own table
-- between rounds; a patch applied once would be silently reverted.
local function scanForSpeedTables()
    seen = {}
    local found = 0

    for _, path in ipairs(CANDIDATE_PATHS) do
        local inst = resolve(split(path))
        if inst then
            local mod = nil
            pcall(function() mod = require(inst) end)
            if type(mod) == "table" then
                found = found + 1
                patchTable(mod, 0)
            end
        end
    end

    scanned = true
    return found
end

--------------------------------------------------------------------
-- Module state
--------------------------------------------------------------------
local FakeDuck = {
    Initialized = false,
    Connection = nil,
    -- Reference speed learned from real upright movement, used by the velocity
    -- layer as a fallback for a build that caps velocity rather than reading a
    -- constant we can reach.
    normalSpeed = 0,
    lastKnownNormal = 16,
    MIN_MOVING = 0.75,
    MAX_GAIN = 1.05,
}

local storedConfig = nil

local function localCharacter()
    local character = nil
    pcall(function()
        character = game:GetService("Players").LocalPlayer.Character
    end)
    return character
end

local function isCrouched(character)
    if not character then return false end
    local crouching = nil
    pcall(function() crouching = character:GetAttribute("IsCrouching") end)
    if type(crouching) == "boolean" then return crouching end
    return false
end

local function rootOf(character)
    local root = nil
    pcall(function() root = character:FindFirstChild("HumanoidRootPart") end)
    return root
end

local function horizontal(v)
    return math.sqrt((v.X * v.X) + (v.Z * v.Z))
end

local SCAN_INTERVAL = 2.0
local lastScanAt = -999
local scanAttempts = 0

local function step()
    if not storedConfig then return end

    local enabled = storedConfig.FAKE_DUCK_ENABLED
    if enabled == nil then enabled = false end
    if not enabled then return end

    -- Keep looking for the speed tables: cheap, and it survives the game
    -- rebuilding its own movement config between rounds.
    if (os.clock() - lastScanAt) > SCAN_INTERVAL then
        lastScanAt = os.clock()
        scanAttempts = scanAttempts + 1
        scanForSpeedTables()
    end

    local character = localCharacter()
    if not character then return end

    local root = rootOf(character)
    if not root then return end

    local velocity = nil
    pcall(function() velocity = root.AssemblyLinearVelocity end)
    if not velocity then return end

    local speed = horizontal(velocity)
    local crouched = isCrouched(character)

    if not crouched then
        if speed > FakeDuck.MIN_MOVING then
            FakeDuck.normalSpeed = math.max(FakeDuck.normalSpeed, speed)
            if FakeDuck.normalSpeed > 1 then
                FakeDuck.lastKnownNormal = FakeDuck.normalSpeed
            end
        end
        return
    end

    -- Keep the display flag consistent with the patched constant. Harmless if the
    -- game re-asserts it, and it keeps the local pose upright.
    pcall(function() character:SetAttribute("IsCrouching", false) end)

    -- Velocity layer: a fallback for a build whose cap is applied to motion
    -- rather than to a constant we can reach.
    local target = FakeDuck.lastKnownNormal
    if target <= FakeDuck.MIN_MOVING then return end
    if speed >= target then return end
    if speed < 0.05 then return end

    local gain = math.min(target * FakeDuck.MAX_GAIN, target) / speed
    if gain <= 1 then return end

    pcall(function()
        root.AssemblyLinearVelocity = Vector3.new(
            velocity.X * gain, velocity.Y, velocity.Z * gain)
    end)
end

-- What the scan can see, and what it changed. Read off this rather than inferred
-- from whether the speed feels right.
FakeDuck.Report = function()
    local seenList = #seen > 0 and table.concat(seen, ",") or "none"
    local appliedList = #applied > 0 and table.concat(applied, ",") or "none"
    return string.format("FakeDuck mods=%d scanned=%s found=%d[%s] changed=%d[%s]",
        scanAttempts, tostring(scanned), #seen, seenList, #applied, appliedList)
end

function FakeDuck.init(Config)
    if FakeDuck.Initialized then return end
    FakeDuck.Initialized = true

    storedConfig = Config

    -- Patch once immediately so the effect is there before the first crouch - but
    -- only if the feature is actually on. Patching on init while the toggle was
    -- off meant the constants were rewritten for every session whether the user
    -- wanted fake duck or not, which is not a thing a disabled toggle should do.
    local enabled = nil
    pcall(function() enabled = Config and Config.FAKE_DUCK_ENABLED end)
    if enabled then
        pcall(function() scanForSpeedTables() end)
    end

    FakeDuck.Connection = RunService.Heartbeat:Connect(function()
        pcall(step)
    end)
end

function FakeDuck.cleanup()
    if FakeDuck.Connection then
        pcall(function() FakeDuck.Connection:Disconnect() end)
        FakeDuck.Connection = nil
    end
    FakeDuck.normalSpeed = 0
    FakeDuck.lastKnownNormal = 16
    seen = {}
    applied = {}
    appliedSet = {}
    scanned = false
    lastScanAt = -999
    scanAttempts = 0
    storedConfig = nil
    FakeDuck.Initialized = false
end

return FakeDuck

