-- silent aim and aimbot
-- The original bullet redirection is untouched: BulletModule._performRaycast is
-- swapped for a version that rebuilds the bullet ray so it travels towards the
-- target instead of the crosshair. Tracer push, hit sound, the natural fallback
-- raycast and the NO_SPREAD handling all behave exactly like before.
--
-- Everything else is layerd on top and is gated behind AIM_* config keys. Every
-- read falls back to a default, so with none of them set the module behaves the
-- same way the old one did.
--
-- Notes on a few of the switches:
--   * AIM_TARGET_MODE picks the victim: FOV / Nearest / LowestHP / HighestHP
--   * AIM_FOV_DEG caps how far off the crosshair a target may be, AIM_SILENT360
--     removes that cap completely
--   * AIM_VISIBLE_CHECK drops occluded targets, AIM_WALLBANG plus
--     AIM_WALLBANG_MODE let the shot go through anyway by boosting the
--     penetration value used to build the hit data
--   * AIM_RESOLVER is a *simple* resolver: the aim point is pulled towards the
--     HumanoidRootPart horizontally, which is enough to shrug off a fake lean
--   * AIM_MIN_DAMAGE only gets Utils here and no DamageEngine, so it filters by
--     health instead of computing real damage: targets whose current health is
--     already below the value are skipped so we do not waste shots on them
--   * the target part already chosen by TargetEngine is kept whenever it belongs
--     to the character we picked, so nothing regresses for existing configs

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

-- absent on some executors, so never index it directly
local VirtualInputManagerLib = nil
pcall(function()
    VirtualInputManagerLib = game:GetService("VirtualInputManager")
end)

local DrawingLib = nil
do
    local okLib, lib = pcall(function() return Drawing end)
    if okLib and lib ~= nil then
        DrawingLib = lib
    end
end

local BulletModule = require(ReplicatedStorage.Components.Weapon.Classes.Bullet)
local GetRayIgnore = require(ReplicatedStorage.Components.Common.GetRayIgnore)
local Raycast = require(ReplicatedStorage.Shared.Raycast)

local cast = Raycast.cast
local castThrough = Raycast.castThrough

local min = math.min
local max = math.max
local rad = math.rad
local abs = math.abs
local clamp = math.clamp

local SilentAim = {
    Initialized = false,
    Connection = nil,
    AutoFireActive = false,
    AutoFireBusy = false,
    AutoFireReleaseAt = 0,
    LastAutoFire = 0
}

local storedConfig = nil
local storedUtils = nil
local storedHitSound = nil
local storedBulletTracer = nil

local lastPickTime = 0
local cachedPickChar = nil
local cachedPickPart = nil

local healthTracker = {}
local lastHealthPrune = 0

local backtrackHistory = {}
local hitboxRecords = {}
local expandedParts = {}

local scopeLines = {}
local scopeDot = nil

local hitMarkerLines = {}
local hitMarkerUntil = 0

local damageNumbers = {}
local damageNumberKey = 0

local TARGET_REFRESH_INTERVAL = 0.05
local HITBOX_PART_NAMES = {"Head", "UpperTorso", "Torso", "LowerTorso"}
local ARCHETYPE_PART_NAMES = {"Head", "UpperTorso", "Torso", "LowerTorso", "HumanoidRootPart"}
local PREDICTION_PROJECTILE_SPEED = 3000
local BACKTRACK_MAX_ENTRIES = 64
local DAMAGE_NUMBER_LIFETIME = 0.9
local DAMAGE_NUMBER_RISE = 42
local MAX_DAMAGE_NUMBERS = 24
local AUTO_FIRE_RELEASE_TIME = 0.012
local HIT_MARKER_DURATION = 0.25

local SCOPE_DIRECTIONS = {
    Vector2.new(0, -1),
    Vector2.new(0, 1),
    Vector2.new(-1, 0),
    Vector2.new(1, 0)
}

local MARKER_DIRECTIONS = {
    Vector2.new(-1, -1),
    Vector2.new(1, 1),
    Vector2.new(1, -1),
    Vector2.new(-1, 1)
}

local function nativeRaycastWithSpread(self, spread)
    local ignoreList = GetRayIgnore()
    local cam = Workspace.CurrentCamera
    local vpCenter = cam.ViewportSize * 0.5
    local vpRay = cam:ViewportPointToRay(vpCenter.X, vpCenter.Y)
    spread = min(spread or 0, 69)
    local rng = Random.new(math.floor((os.clock() * 1e6) % 2147483647))
    local theta = rng:NextNumber(-math.pi, math.pi)
    local phi = rng:NextNumber(0, rad(spread * 0.5))
    local dir = vpRay.Direction
    local unitDir = (dir.Magnitude > 0) and dir.Unit or Vector3.new(0, 0, 1)
    local up = (abs(unitDir.Y) <= 0.9999) and Vector3.new(0, 1, 0) or Vector3.new(1, 0, 0)
    local lookVector = ((CFrame.lookAlong(Vector3.new(0, 0, 0), unitDir, up) * CFrame.Angles(0, 0, theta)) * CFrame.Angles(phi, 0, 0)).LookVector
    local origin = vpRay.Origin
    local penetration = (self.Properties and self.Properties.Penetration) or 0
    local range = (self.Properties and self.Properties.Range) or 500

    local hitData = {
        Distance = 0,
        Origin = origin,
        Direction = lookVector,
        Hits = {}
    }

    local hitInfo = cast(origin, lookVector * range, nil, ignoreList)
    if hitInfo and hitInfo.instance then
        local pos = hitInfo.position
        hitData.Distance = (pos - origin).Magnitude
        local penetrationHits = castThrough(pos + lookVector * -0.001, lookVector * (penetration + 0.001), penetration, ignoreList)
        if penetrationHits then
            for i = 1, #penetrationHits do
                local pHit = penetrationHits[i]
                if pHit.instance and pHit.material then
                    table.insert(hitData.Hits, {
                        Position = pHit.position,
                        Instance = pHit.instance,
                        Material = (pHit.material and pHit.material.Name) or tostring(pHit.material),
                        Normal = pHit.normal or Vector3.new(0, 0, 0),
                        Exit = (i % 2 == 0)
                    })
                end
            end
        end
    else
        hitData.Distance = range
    end

    return hitData
end

-- config reads: every key falls back to a default so a missing key can never
-- break the aim. `nil` is returned when the module was not initialised yet.
local function cfgValue(key)
    if not storedConfig then return nil end
    return storedConfig[key]
end

local function cfgBool(key, default)
    local value = cfgValue(key)
    if value == nil then return default end
    return (value == true)
end

local function cfgNum(key, default)
    local value = tonumber(cfgValue(key))
    if value == nil then return default end
    return value
end

local function cfgString(key, default)
    local value = cfgValue(key)
    if type(value) == "string" then return value end
    return default
end

local function cfgColor(key, default)
    local value = cfgValue(key)
    if value ~= nil then
        local okKind, kind = pcall(function() return typeof(value) end)
        if okKind and kind == "Color3" then
            return value
        end
    end
    return default
end

-- drawing helpers
local function newDrawing(kind)
    if not DrawingLib then return nil end
    local okCreated, obj = pcall(function() return DrawingLib.new(kind) end)
    if okCreated and obj then return obj end
    return nil
end

local function removeDrawing(obj)
    if not obj then return end
    pcall(function() obj.Visible = false end)
    pcall(function() obj:Remove() end)
end

local function setDrawingProps(obj, props)
    if not obj then return end
    pcall(function()
        for key, value in pairs(props) do
            obj[key] = value
        end
    end)
end

local function clearDrawingList(list)
    for i = 1, #list do
        removeDrawing(list[i])
        list[i] = nil
    end
end

local function screenCenter()
    local cam = Workspace.CurrentCamera
    if not cam then return Vector2.new(0, 0) end

    local okSize, size = pcall(function() return cam.ViewportSize end)
    if okSize and size then
        return Vector2.new(size.X * 0.5, size.Y * 0.5)
    end

    return Vector2.new(0, 0)
end

local function getCharactersFolder()
    return Workspace:FindFirstChild("Characters")
end

local function hasUtil(name)
    return (storedUtils ~= nil) and (type(storedUtils[name]) == "function")
end

local function getHealth(char)
    if not char then return 0, 100 end

    if hasUtil("getCharacterHealth") then
        local okHealth, hp, maxHp = pcall(storedUtils.getCharacterHealth, char)
        if okHealth and type(hp) == "number" then
            local knownMax = 100
            if type(maxHp) == "number" and maxHp > 0 then
                knownMax = maxHp
            end
            return hp, knownMax
        end
    end

    local okAttr, attr = pcall(function() return tonumber(char:GetAttribute("Health")) end)
    if okAttr and type(attr) == "number" then
        return attr, 100
    end

    return 0, 100
end

local function isEnemyChar(char)
    if not char then return false end

    if hasUtil("isEnemy") then
        local player = Players:FindFirstChild(char.Name)
        local okEnemy, enemy = pcall(storedUtils.isEnemy, player, char)
        if okEnemy then
            return (enemy ~= false)
        end
    end

    return true
end

local function isAliveChar(char)
    if not char or not char.Parent then return false end
    if char:GetAttribute("Dead") == true then return false end
    return getHealth(char) > 0
end

local function isOccluded(part, char)
    if not part then return true end

    if hasUtil("isPartOccluded") then
        local okOcc, occluded = pcall(storedUtils.isPartOccluded, part, char)
        if okOcc and type(occluded) == "boolean" then
            return occluded
        end
    end

    return false
end

local function headPartOf(char)
    if not char then return nil end

    local head = char:FindFirstChild("Head")
    if head and head:IsA("BasePart") then
        return head
    end

    local root = char:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") then
        return root
    end

    return nil
end

local function angleToDeg(worldPos, camPos, camLook)
    local dir = worldPos - camPos
    local magnitude = dir.Magnitude
    if magnitude <= 0 then return 0 end

    local dot = clamp(camLook:Dot(dir / magnitude), -1, 1)
    return math.deg(math.acos(dot))
end

-- wallbang: the mode decides how much penetration we hand the raycast
local WALLBANG_MULTIPLIER = {
    None = 0,
    Some = 1,
    Much = 2,
    All = 9999
}

local function wallbangMode()
    local raw = cfgValue("AIM_WALLBANG_MODE")
    if type(raw) ~= "string" then
        return (cfgBool("AIM_WALLBANG", false)) and "Much" or "None"
    end
    return raw
end

local function wallbangMultiplier()
    if not cfgBool("AIM_WALLBANG", false) then
        return 0
    end

    local mode = wallbangMode()
    local mapped = WALLBANG_MULTIPLIER[mode]

    if mapped == nil then
        return 0
    end

    return mapped
end

local function wallbangAllowed()
    return wallbangMultiplier() > 0
end

-- None leaves the weapon penetration alone, otherwise it gets scaled up so the
-- reported hit data actually reaches through the surface
local function effectivePenetration(base, multiplier)
    if multiplier <= 0 then
        return base
    end

    local boosted = base * multiplier

    if boosted < base then
        boosted = base
    end

    if multiplier >= 9999 then
        boosted = max(boosted, 500)
    end

    return boosted
end

-- backtrack: keep a short trail of where each character was
local function recordBacktrack(char, position)
    if not char or not position then return end

    local now = os.clock()
    local history = backtrackHistory[char]

    if not history then
        history = {}
        backtrackHistory[char] = history
    end

    history[#history + 1] = { Time = now, Position = position }

    while #history > BACKTRACK_MAX_ENTRIES do
        table.remove(history, 1)
    end
end

local function backtrackPosition(char)
    if not char then return nil end

    local history = backtrackHistory[char]
    if not history or (#history < 2) then
        return nil
    end

    local targetTime = os.clock() - cfgNum("AIM_BACKTRACK_TIME", 0.2)

    for i = #history, 1, -1 do
        if history[i].Time <= targetTime then
            return history[i].Position
        end
    end

    return history[1].Position
end

-- rough travel speed of the character, used to lead running targets
local function estimateSpeed(char, part)
    if part then
        local okVel, velocity = pcall(function() return part.AssemblyLinearVelocity end)
        if okVel and type(velocity) == "Vector3" then
            return velocity.Magnitude
        end
    end

    local history = backtrackHistory[char]
    if history and (#history >= 2) then
        local first = history[1]
        local last = history[#history]
        local span = last.Time - first.Time
        if span > 0 then
            return (last.Position - first.Position).Magnitude / span
        end
    end

    return 16
end

local function predictionOffset(char, part, aimPos, origin)
    local mode = cfgString("AIM_PREDICTION_MODE", "Off")
    if mode == "Off" then
        return Vector3.new(0, 0, 0)
    end

    local distance = (aimPos - origin).Magnitude
    local travelTime = distance / PREDICTION_PROJECTILE_SPEED
    local scale = cfgNum("AIM_PREDICTION_SCALE", 1)

    local velocity = nil

    if mode == "CFrame" then
        local source = char and (char:FindFirstChild("HumanoidRootPart") or nil)
        if not source or (not source:IsA("BasePart")) then
            source = part
        end

        if source then
            local okLook, look = pcall(function() return source.CFrame.LookVector end)
            if okLook and type(look) == "Vector3" then
                velocity = look * estimateSpeed(char, part)
            end
        end
    else
        local okVel, linear = pcall(function() return part.AssemblyLinearVelocity end)
        if okVel and type(linear) == "Vector3" then
            velocity = linear
        end

        if not velocity then
            local history = backtrackHistory[char]
            if history and (#history >= 2) then
                local first = history[1]
                local last = history[#history]
                local span = last.Time - first.Time
                if span > 0 then
                    velocity = (last.Position - first.Position) / span
                end
            end
        end
    end

    if not velocity then
        return Vector3.new(0, 0, 0)
    end

    return velocity * travelTime * scale
end

-- where exactly the bullet gets aimed, the plain part position unless something
-- is switched on
local function computeAimPoint(char, part, origin)
    local aimPos = part.Position

    if cfgBool("AIM_MULTIPOINT_ENABLED", false) then
        local percent = clamp(cfgNum("AIM_MULTIPOINT", 0) / 100, 0, 1)
        if percent > 0 then
            local size = part.Size
            aimPos = aimPos + Vector3.new(
                (math.random() - 0.5) * size.X * percent,
                (math.random() - 0.5) * size.Y * percent,
                (math.random() - 0.5) * size.Z * percent
            )
        end
    end

    if cfgBool("AIM_RESOLVER", false) and char then
        local root = char:FindFirstChild("HumanoidRootPart")
        if root and root:IsA("BasePart") then
            local rootPos = root.Position
            aimPos = Vector3.new(
                aimPos.X + (rootPos.X - aimPos.X) * 0.5,
                aimPos.Y,
                aimPos.Z + (rootPos.Z - aimPos.Z) * 0.5
            )
        end
    end

    if cfgBool("AIM_BACKTRACK_ENABLED", false) then
        local pastPos = backtrackPosition(char)
        if pastPos then
            aimPos = pastPos
        end
    end

    local offset = predictionOffset(char, part, aimPos, origin)
    if offset ~= nil then
        aimPos = aimPos + offset
    end

    return aimPos
end

-- which part of the character we line the shot up on
local function chooseTargetPart(char)
    if not char then return nil end

    if cfgBool("AIM_HEAD_HOOK", false) then
        return headPartOf(char)
    end

    -- keep whatever TargetEngine already picked so old behaviour stays intact
    local existing = cfgValue("CurrentTargetPart")
    if existing and existing.Parent == char and existing:IsA("BasePart") then
        if wallbangAllowed() or (not isOccluded(existing, char)) then
            return existing
        end
    end

    local fallback = nil

    for i = 1, #ARCHETYPE_PART_NAMES do
        local part = char:FindFirstChild(ARCHETYPE_PART_NAMES[i])
        if part and part:IsA("BasePart") then
            if not isOccluded(part, char) then
                return part
            end
            if not fallback then
                fallback = part
            end
        end
    end

    return fallback
end

local function sortCandidates(list, mode)
    if mode == "Nearest" then
        table.sort(list, function(a, b) return a.Distance < b.Distance end)
    elseif mode == "LowestHP" then
        table.sort(list, function(a, b) return a.Health < b.Health end)
    elseif mode == "HighestHP" then
        table.sort(list, function(a, b) return a.Health > b.Health end)
    else
        table.sort(list, function(a, b) return a.Angle < b.Angle end)
    end
end

-- full scan of the characters folder, returns the character and the part to shoot
local function scanTargets()
    local charsFolder = getCharactersFolder()
    if not charsFolder then return nil, nil end

    local cam = Workspace.CurrentCamera
    if not cam then return nil, nil end

    local camPos = cam.CFrame.Position
    local camLook = cam.CFrame.LookVector

    local silent360 = cfgBool("AIM_SILENT360", false)
    local fovLimit = cfgNum("AIM_FOV_DEG", 30)
    if fovLimit < 0 then
        fovLimit = 0
    end

    local minDamage = cfgNum("AIM_MIN_DAMAGE", 0)
    local priorityName = cfgString("AIM_PRIORITY_TARGET", "")
    local usePriority = cfgBool("AIM_PRIORITY_ENABLED", false) and (priorityName ~= "")

    local list = {}
    local priorityEntry = nil

    for _, char in ipairs(charsFolder:GetChildren()) do
        if char:IsA("Model") and char.Parent == charsFolder and char.Name ~= LocalPlayer.Name then
            if isAliveChar(char) and isEnemyChar(char) then
                local hp = getHealth(char)

                -- AIM_MIN_DAMAGE: skip players that are already weaker than the
                -- configured damage, there is nothing worth shooting left on them
                if hp >= minDamage then
                    local head = headPartOf(char)
                    if head then
                        local angle = angleToDeg(head.Position, camPos, camLook)
                        local entry = {
                            Char = char,
                            Head = head,
                            Angle = angle,
                            Distance = (head.Position - camPos).Magnitude,
                            Health = hp
                        }

                        if usePriority and char.Name == priorityName then
                            priorityEntry = entry
                        end

                        if silent360 or (angle <= fovLimit) then
                            list[#list + 1] = entry
                        end
                    end
                end
            end
        end
    end

    sortCandidates(list, cfgString("AIM_TARGET_MODE", "FOV"))

    local ordered = list

    if priorityEntry then
        -- the priority player wins even when outside the fov limit
        ordered = { priorityEntry }
        for i = 1, #list do
            if list[i] ~= priorityEntry then
                ordered[#ordered + 1] = list[i]
            end
        end
    end

    local visibleCheck = cfgBool("AIM_VISIBLE_CHECK", false)
    local canWallbang = wallbangAllowed()

    for i = 1, #ordered do
        local entry = ordered[i]
        local part = chooseTargetPart(entry.Char)

        if part then
            local visible = (not visibleCheck) or canWallbang or (not isOccluded(part, entry.Char))
            if visible then
                return entry.Char, part
            end
        end
    end

    return nil, nil
end

local function pickStillValid()
    if not cachedPickChar or not cachedPickPart then
        return false
    end

    if (not cachedPickPart.Parent) or (not cachedPickPart:IsDescendantOf(Workspace)) then
        return false
    end

    if (cachedPickPart.Parent ~= cachedPickChar) and (not cachedPickPart:IsDescendantOf(cachedPickChar)) then
        return false
    end

    return isAliveChar(cachedPickChar)
end

local function ensureTarget(force)
    local now = os.clock()

    if (not force) and pickStillValid() and ((now - lastPickTime) < TARGET_REFRESH_INTERVAL) then
        return cachedPickChar, cachedPickPart
    end

    lastPickTime = now
    cachedPickChar, cachedPickPart = scanTargets()

    return cachedPickChar, cachedPickPart
end

-- master enable: the old key stays authoritative, AIM_ENABLED can veto it
local function areTargetsEnabled()
    if not storedConfig then return false end

    local fromHook = true
    if type(storedConfig.isSilentAimActive) == "function" then
        local okHook, active = pcall(storedConfig.isSilentAimActive)
        if okHook and type(active) == "boolean" then
            fromHook = active
        end
    end

    return fromHook
        and (storedConfig.SILENT_AIM_ENABLED ~= false)
        and (storedConfig.AIM_ENABLED ~= false)
end

-- per bullet hit chance roll. When the roll fails the shot is left untouched so
-- the bullet simply travels with the weapon's natural spread and misses.
local function rollHitChance()
    local chance = tonumber(cfgValue("AIM_HIT_CHANCE"))

    if chance == nil then
        -- legacy keys from the old silent aim tab
        if cfgValue("HIT_CHANCE_ENABLED") ~= true then
            return true
        end
        chance = tonumber(cfgValue("HIT_CHANCE")) or 100
    end

    if chance >= 100 then return true end
    if chance <= 0 then return false end

    return (math.random() * 100) < chance
end

-- `Hits` only carries penetration surfaces, and weapons with no penetration do not
-- record anything at all. Fall back to re-raycasting along the returned travel
-- vector so we can still see what the bullet actually touched.
local function findHitInstance(result)
    if not result then return nil end

    local hits = result.Hits
    if type(hits) == "table" and #hits > 0 then
        for i = 1, #hits do
            local hit = hits[i]
            if hit and hit.Instance and hit.Exit == false then
                return hit.Instance
            end
        end
        if hits[1] and hits[1].Instance then
            return hits[1].Instance
        end
    end

    local origin = result.Origin
    local direction = result.Direction
    local distance = result.Distance

    if not origin or not direction or not distance or distance <= 0 then
        return nil
    end

    local okIgnore, ignoreList = pcall(GetRayIgnore)
    local okCast, info = pcall(function()
        return cast(origin, direction * (distance + 0.05), nil, okIgnore and ignoreList or nil)
    end)

    if okCast and info and info.instance then
        return info.instance
    end

    return nil
end

-- resolve the character model that owns the hit part, ignoring non-enemy hits
local function resolveEnemyCharacter(instance)
    if not instance then return nil end

    local charsFolder = Workspace:FindFirstChild("Characters")
    if not charsFolder then return nil end
    if not instance:IsDescendantOf(charsFolder) then return nil end

    local model = instance:FindFirstAncestorOfClass("Model")
    if not model or model.Parent ~= charsFolder then return nil end
    if model.Name == LocalPlayer.Name then return nil end
    if model:GetAttribute("Dead") == true then return nil end

    if hasUtil("isEnemy") then
        local plr = Players:FindFirstChild(model.Name)
        local okEnemy, isEnemy = pcall(storedUtils.isEnemy, plr, model)
        if okEnemy and isEnemy == false then
            return nil
        end
    end

    return model
end

-- auto fire
local function sendMousePress(pressed)
    if not VirtualInputManagerLib then return end

    pcall(function()
        local cam = Workspace.CurrentCamera
        local size = cam and cam.ViewportSize or Vector2.new(0, 0)
        VirtualInputManagerLib:SendMouseButtonEvent(size.X * 0.5, size.Y * 0.5, 0, pressed, game, 0)
    end)
end

local function updateAutoFire(hasTarget)
    if not cfgBool("AIM_AUTO_FIRE", false) then
        if SilentAim.AutoFireActive then
            sendMousePress(false)
            SilentAim.AutoFireActive = false
        end
        if SilentAim.AutoFireBusy then
            sendMousePress(false)
            SilentAim.AutoFireBusy = false
        end
        return
    end

    if cfgBool("AIM_AUTO_FIRE_HOLD", true) then
        if hasTarget then
            if not SilentAim.AutoFireActive then
                sendMousePress(true)
                SilentAim.AutoFireActive = true
            end
        elseif SilentAim.AutoFireActive then
            sendMousePress(false)
            SilentAim.AutoFireActive = false
        end
        return
    end

    local now = os.clock()
    local interval = cfgNum("AIM_AUTO_FIRE_DELAY", 0.05)
    if interval <= 0 then
        interval = 0.001
    end

    if hasTarget and (not SilentAim.AutoFireBusy) and ((now - SilentAim.LastAutoFire) >= interval) then
        SilentAim.LastAutoFire = now
        SilentAim.AutoFireBusy = true
        SilentAim.AutoFireReleaseAt = now + AUTO_FIRE_RELEASE_TIME
        sendMousePress(true)
    end

    if SilentAim.AutoFireBusy and (now >= SilentAim.AutoFireReleaseAt) then
        sendMousePress(false)
        SilentAim.AutoFireBusy = false
    end
end

-- hitbox expander: remembers what it touched so it can put it back
local function restoreHitbox(part)
    local record = hitboxRecords[part]
    if not record then return end

    pcall(function()
        part.Size = record.Size
        part.Transparency = record.Transparency
    end)

    hitboxRecords[part] = nil
    expandedParts[part] = nil
end

local function restoreAllHitboxes()
    local open = {}

    for part in pairs(expandedParts) do
        open[#open + 1] = part
    end

    for i = 1, #open do
        restoreHitbox(open[i])
    end
end

local function updateHitboxes(char)
    if (not cfgBool("AIM_HITBOX_ENABLED", false)) or (not char) then
        restoreAllHitboxes()
        return
    end

    local multiplier = cfgNum("AIM_HITBOX_SIZE", 2)
    if multiplier <= 0 then
        multiplier = 1
    end

    local transparency = clamp(cfgNum("AIM_HITBOX_TRANSPARENCY", 1), 0, 1)

    local stale = {}
    for part in pairs(expandedParts) do
        if part.Parent ~= char then
            stale[#stale + 1] = part
        end
    end

    for i = 1, #stale do
        restoreHitbox(stale[i])
    end

    for i = 1, #HITBOX_PART_NAMES do
        local part = char:FindFirstChild(HITBOX_PART_NAMES[i])
        if part and part:IsA("BasePart") and (not hitboxRecords[part]) then
            hitboxRecords[part] = { Size = part.Size, Transparency = part.Transparency }
            expandedParts[part] = true

            pcall(function()
                part.Size = part.Size * multiplier
                part.Transparency = transparency
            end)
        end
    end
end

-- floating damage numbers
local function clearDamageNumbers()
    for key, entry in pairs(damageNumbers) do
        removeDrawing(entry.Text)
        damageNumbers[key] = nil
    end
end

local function pushDamageNumber(char, damage)
    if not cfgBool("AIM_DAMAGE_NUMBERS", false) then return end

    local part = headPartOf(char)
    if not part then return end

    local count = 0
    for _ in pairs(damageNumbers) do
        count = count + 1
    end
    if count >= MAX_DAMAGE_NUMBERS then
        return
    end

    local text = newDrawing("Text")
    if not text then return end

    setDrawingProps(text, {
        Size = 14,
        Center = true,
        Outline = true,
        Visible = false
    })

    damageNumberKey = damageNumberKey + 1

    damageNumbers[damageNumberKey] = {
        Text = text,
        Part = part,
        Damage = damage,
        Born = os.clock()
    }
end

local function updateDamageNumbers()
    local now = os.clock()
    local expired = nil

    for key, entry in pairs(damageNumbers) do
        local age = now - entry.Born

        if age >= DAMAGE_NUMBER_LIFETIME then
            expired = expired or {}
            expired[#expired + 1] = key
        else
            local drawn = false
            local part = entry.Part

            if part and part.Parent then
                local cam = Workspace.CurrentCamera
                local okScreen, screen = pcall(cam.WorldToViewportPoint, cam, part.Position)

                if okScreen and screen and screen.Z > 0 then
                    drawn = true
                    local t = clamp(age / DAMAGE_NUMBER_LIFETIME, 0, 1)

                    pcall(function()
                        entry.Text.Visible = true
                        entry.Text.Text = string.format("%d", math.floor(entry.Damage + 0.5))
                        entry.Text.Position = Vector2.new(screen.X, screen.Y - (t * DAMAGE_NUMBER_RISE))
                        entry.Text.Color = Color3.fromRGB(255, math.floor(255 - (t * 150)), 60)
                        entry.Text.Transparency = 1 - t
                    end)
                end
            end

            if not drawn then
                setDrawingProps(entry.Text, { Visible = false })
            end
        end
    end

    if expired then
        for i = 1, #expired do
            local entry = damageNumbers[expired[i]]
            if entry then
                removeDrawing(entry.Text)
            end
            damageNumbers[expired[i]] = nil
        end
    end
end

-- hit marker
local function drawHitMarker()
    if not cfgBool("AIM_HIT_MARKER", false) then return end

    hitMarkerUntil = os.clock() + HIT_MARKER_DURATION

    if #hitMarkerLines > 0 then return end

    for i = 1, #MARKER_DIRECTIONS do
        local line = newDrawing("Line")
        if not line then break end

        setDrawingProps(line, {
            Thickness = 2,
            Visible = false
        })

        hitMarkerLines[#hitMarkerLines + 1] = line
    end
end

local function updateHitMarker()
    local lines = #hitMarkerLines
    if lines == 0 then return end

    local visible = os.clock() < hitMarkerUntil
    local center = screenCenter()
    local gap = clamp(cfgNum("AIM_SCOPE_GAP", 4), 0, 400)
    local size = clamp(cfgNum("AIM_SCOPE_SIZE", 20), 1, 400)
    local color = cfgColor("AIM_HIT_MARKER_COLOR", Color3.fromRGB(255, 255, 255))

    for i = 1, lines do
        local line = hitMarkerLines[i]
        local dir = MARKER_DIRECTIONS[i]

        pcall(function()
            line.Visible = visible
            if not visible then return end
            line.Color = color
            line.Thickness = clamp(cfgNum("AIM_SCOPE_THICKNESS", 2), 1, 20)
            line.From = center + dir * (gap + (size * 0.5))
            line.To = center + dir * (gap + (size * 0.5) + (size * 0.6))
        end)
    end
end

-- custom scope
local function hideScope()
    for i = 1, #scopeLines do
        setDrawingProps(scopeLines[i], { Visible = false })
    end

    if scopeDot then
        setDrawingProps(scopeDot, { Visible = false })
    end
end

local function ensureScopeObjects()
    while #scopeLines < #SCOPE_DIRECTIONS do
        local line = newDrawing("Line")
        if not line then break end

        setDrawingProps(line, {
            Thickness = clamp(cfgNum("AIM_SCOPE_THICKNESS", 2), 1, 20),
            Visible = false
        })

        scopeLines[#scopeLines + 1] = line
    end
end

local function updateScope()
    if not cfgBool("AIM_CUSTOM_SCOPE", false) then
        hideScope()
        return
    end

    ensureScopeObjects()

    local center = screenCenter()
    local size = clamp(cfgNum("AIM_SCOPE_SIZE", 20), 1, 400)
    local gap = clamp(cfgNum("AIM_SCOPE_GAP", 4), 0, 400)
    local thickness = clamp(cfgNum("AIM_SCOPE_THICKNESS", 2), 1, 20)
    local color = cfgColor("AIM_SCOPE_COLOR", Color3.fromRGB(255, 255, 255))

    for i = 1, #scopeLines do
        local line = scopeLines[i]
        local dir = SCOPE_DIRECTIONS[i]

        pcall(function()
            line.Visible = true
            line.Thickness = thickness
            line.Color = color
            line.From = center + dir * gap
            line.To = center + dir * (gap + size)
        end)
    end

    if cfgBool("AIM_SCOPE_DOT", false) then
        if not scopeDot then
            scopeDot = newDrawing("Circle")
            setDrawingProps(scopeDot, { Thickness = 1, Filled = true, Transparency = 1, Visible = false })
        end

        if scopeDot then
            setDrawingProps(scopeDot, {
                Visible = true,
                Color = color,
                Radius = clamp(cfgNum("AIM_SCOPE_DOT_SIZE", 2), 1, 20),
                Position = center
            })
        end
    elseif scopeDot then
        removeDrawing(scopeDot)
        scopeDot = nil
    end
end

-- on hit feedback: marker plus a floating number on the character we damaged
local function handleHit(char, damage)
    drawHitMarker()
    pushDamageNumber(char, damage)
end

-- watches health values so we notice hits without needing init.lua to call us
local function updateFeedback()
    local charsFolder = getCharactersFolder()
    if not charsFolder then return end

    local now = os.clock()
    local seen = {}

    for _, char in ipairs(charsFolder:GetChildren()) do
        if char:IsA("Model") and char.Name ~= LocalPlayer.Name and isEnemyChar(char) then
            seen[char.Name] = true

            local hp = getHealth(char)
            local previous = healthTracker[char.Name]

            if previous and (hp < previous) then
                local damage = previous - hp
                if damage > 0 and damage < 1000 then
                    handleHit(char, damage)
                end
            end

            healthTracker[char.Name] = hp
        end
    end

    if (now - lastHealthPrune) > 10 then
        lastHealthPrune = now

        for name in pairs(healthTracker) do
            if not seen[name] then
                healthTracker[name] = nil
            end
        end

        for char in pairs(backtrackHistory) do
            if not seen[char.Name] then
                backtrackHistory[char] = nil
            end
        end
    end
end

local function updateDrawings()
    updateScope()
    updateHitMarker()
    updateDamageNumbers()
end

local function hideAllDrawings()
    hideScope()
    clearDamageNumbers()

    for i = 1, #hitMarkerLines do
        setDrawingProps(hitMarkerLines[i], { Visible = false })
    end
end

local function destroyAllDrawings()
    clearDrawingList(scopeLines)
    removeDrawing(scopeDot)
    scopeDot = nil

    clearDamageNumbers()
    clearDrawingList(hitMarkerLines)

    hitMarkerUntil = 0
end

local function releaseAutoFire()
    if SilentAim.AutoFireActive then
        sendMousePress(false)
        SilentAim.AutoFireActive = false
    end

    if SilentAim.AutoFireBusy then
        sendMousePress(false)
        SilentAim.AutoFireBusy = false
    end
end

local function update()
    if not storedConfig then return end

    if not areTargetsEnabled() then
        cachedPickChar = nil
        cachedPickPart = nil
        restoreAllHitboxes()
        hideAllDrawings()
        releaseAutoFire()
        return
    end

    local char, part = ensureTarget(false)

    if char and part then
        pcall(function() recordBacktrack(char, part.Position) end)
    end

    pcall(function() updateHitboxes(char) end)
    pcall(function() updateAutoFire(char ~= nil) end)
    pcall(updateFeedback)
    pcall(updateDrawings)
end

function SilentAim.init(Config, Utils, HitSound, BulletTracer)
    if SilentAim.Initialized then return end
    SilentAim.Initialized = true

    storedConfig = Config
    storedUtils = Utils
    storedHitSound = HitSound
    storedBulletTracer = BulletTracer

    local notifyHit = function(result)
        if not HitSound then return end
        if Config.HITSOUND_ENABLED ~= true then return end
        if not HitSound.isReady or not HitSound.isReady() then return end

        local ok, hitPart = pcall(findHitInstance, result)
        if not ok or not hitPart then return end

        local okChar, char = pcall(resolveEnemyCharacter, hitPart)
        if okChar and char then
            HitSound.play(char)
        end
    end

    local finishShot = function(result)
        notifyHit(result)

        if BulletTracer and BulletTracer.push then
            pcall(BulletTracer.push, result, Config)
        end
    end

    local recordShot = function()
        if not HitSound then return end
        if type(HitSound.setShot) ~= "function" then return end
        HitSound.setShot(Config.CurrentTargetChar)
    end

    if not _G.__originalPerformRaycast then
        _G.__originalPerformRaycast = BulletModule._performRaycast
    end

    -- bullet raycast redirection
    local function silentAimPerformRaycast(self, spread)
        local pickChar, pickPart = nil, nil
        pcall(function()
            pickChar, pickPart = ensureTarget(true)
        end)

        -- tell the rest of the cheat who we are shooting at, TargetEngine will
        -- overwrite it again on its next frame
        if pickChar and pickPart then
            Config.CurrentTargetChar = pickChar
            Config.CurrentTargetPart = pickPart
        end

        recordShot()

        local aimActive = areTargetsEnabled()
        local targetPart = pickPart or Config.CurrentTargetPart
        local targetChar = pickChar or ((targetPart and targetPart.Parent) or nil)
        local active = aimActive and rollHitChance()

        if active and targetPart and targetPart.Parent and targetPart:IsDescendantOf(Workspace) then
            local char = targetChar
            if char and not (char:GetAttribute("Dead") == true) then
                local isOccluded = false
                if Config.AIM_OCCLUSION_CHECK then
                    if Utils and Utils.areAllHitboxesOccluded then
                        isOccluded = Utils.areAllHitboxesOccluded(char)
                    end
                end

                if (not isOccluded) or wallbangAllowed() then
                    local success, result = pcall(function()
                        local ignoreList = GetRayIgnore()
                        local cam = Workspace.CurrentCamera
                        local vpCenter = cam.ViewportSize * 0.5
                        local vpRay = cam:ViewportPointToRay(vpCenter.X, vpCenter.Y)
                        local Origin = vpRay.Origin

                        local targetPos = computeAimPoint(char, targetPart, Origin)
                        local LookVector = (targetPos - Origin).Unit
                        local totalDistance = (targetPos - Origin).Magnitude
                        local range = math.max((self.Properties and self.Properties.Range) or 500, totalDistance + 50)
                        local penetration = effectivePenetration((self.Properties and self.Properties.Penetration) or 0, wallbangMultiplier())

                        local hitData = {
                            Distance = totalDistance,
                            Origin = Origin,
                            Direction = LookVector,
                            Hits = {}
                        }

                        local hitInfo = cast(Origin, LookVector * range, nil, ignoreList)
                        if hitInfo and hitInfo.instance then
                            local hitPos = hitInfo.position
                            hitData.Distance = (hitPos - Origin).Magnitude

                            local penetrationHits = castThrough(hitPos + LookVector * -0.001, LookVector * (penetration + 0.001), penetration, ignoreList)
                            if penetrationHits then
                                for i = 1, #penetrationHits do
                                    local pHit = penetrationHits[i]
                                    if pHit.instance and pHit.material then
                                        table.insert(hitData.Hits, {
                                            Position = pHit.position,
                                            Instance = pHit.instance,
                                            Material = (pHit.material and pHit.material.Name) or tostring(pHit.material),
                                            Normal = pHit.normal or Vector3.new(0, 0, 0),
                                            Exit = (i % 2 == 0)
                                        })
                                    end
                                end
                            end
                        end

                        return hitData
                    end)

                    if success and result and result.Hits then
                        finishShot(result)
                        return result
                    end
                end
            end
        end

        -- no spread: the deviation value is what the native raycast uses
        local effectiveSpread = (Config.NO_SPREAD == true) and 0 or spread

        local fallbackResult
        if _G.__originalPerformRaycast and _G.__originalPerformRaycast ~= silentAimPerformRaycast then
            fallbackResult = _G.__originalPerformRaycast(self, effectiveSpread)
        else
            fallbackResult = nativeRaycastWithSpread(self, effectiveSpread)
        end

        finishShot(fallbackResult)

        return fallbackResult
    end

    BulletModule._performRaycast = silentAimPerformRaycast

    SilentAim.Connection = RunService.RenderStepped:Connect(function()
        pcall(update)
    end)
end

-- called by updateFeedback, and also exposed so anything else can report a hit
function SilentAim.onHit(char, damage)
    if type(char) ~= "table" then return end

    local amount = tonumber(damage)
    if not amount or amount <= 0 then return end

    pcall(handleHit, char, amount)
end

function SilentAim.getCurrentTarget()
    return cachedPickChar, cachedPickPart
end

function SilentAim.isTargetScanned()
    return cachedPickChar ~= nil
end

function SilentAim.cleanup()
    pcall(function()
        if SilentAim.Connection then
            SilentAim.Connection:Disconnect()
            SilentAim.Connection = nil
        end
    end)

    releaseAutoFire()
    restoreAllHitboxes()
    destroyAllDrawings()

    if _G.__originalPerformRaycast then
        pcall(function() BulletModule._performRaycast = _G.__originalPerformRaycast end)
    end
    _G.__originalPerformRaycast = nil

    for char in pairs(backtrackHistory) do
        backtrackHistory[char] = nil
    end

    for name in pairs(healthTracker) do
        healthTracker[name] = nil
    end

    damageNumberKey = 0
    lastPickTime = 0
    cachedPickChar = nil
    cachedPickPart = nil

    storedConfig = nil
    storedUtils = nil
    storedHitSound = nil
    storedBulletTracer = nil

    SilentAim.Initialized = false
end

return SilentAim
