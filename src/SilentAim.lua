-- silent aim and recoil hook
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local SilentAim = {}

local BulletModule = require(ReplicatedStorage.Components.Weapon.Classes.Bullet)
local GetRayIgnore = require(ReplicatedStorage.Components.Common.GetRayIgnore)
local Raycast = require(ReplicatedStorage.Shared.Raycast)

local cast = Raycast.cast
local castThrough = Raycast.castThrough

local min = math.min
local rad = math.rad
local abs = math.abs

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

-- per-bullet hit chance roll. When the roll fails the shot is left untouched so
-- the bullet simply travels with the weapon's natural spread and misses.
local function rollHitChance(Config)
    if Config.HIT_CHANCE_ENABLED ~= true then
        return true
    end

    local chance = tonumber(Config.HIT_CHANCE) or 100
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
local function resolveEnemyCharacter(instance, Utils)
    if not instance then return nil end

    local charsFolder = Workspace:FindFirstChild("Characters")
    if not charsFolder then return nil end
    if not instance:IsDescendantOf(charsFolder) then return nil end

    local model = instance:FindFirstAncestorOfClass("Model")
    if not model or model.Parent ~= charsFolder then return nil end
    if model.Name == LocalPlayer.Name then return nil end
    if model:GetAttribute("Dead") == true then return nil end

    if Utils and Utils.isEnemy then
        local plr = Players:FindFirstChild(model.Name)
        local okEnemy, isEnemy = pcall(Utils.isEnemy, plr, model)
        if okEnemy and isEnemy == false then
            return nil
        end
    end

    return model
end

function SilentAim.init(Config, Utils, HitSound)
    local notifyHit = function(result)
        if not HitSound then return end
        if Config.HITSOUND_ENABLED ~= true then return end
        if not HitSound.isReady or not HitSound.isReady() then return end

        local ok, hitPart = pcall(findHitInstance, result)
        if not ok or not hitPart then return end

        local okChar, char = pcall(resolveEnemyCharacter, hitPart, Utils)
        if okChar and char then
            HitSound.play(char)
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
        recordShot()

        local aimActive = (type(Config.isSilentAimActive) == "function") and Config.isSilentAimActive() or (Config.SILENT_AIM_ENABLED ~= false)
        local targetPart = Config.CurrentTargetPart
        local active = aimActive and rollHitChance(Config)

        if active and targetPart and targetPart.Parent and targetPart:IsDescendantOf(Workspace) then
            local char = targetPart.Parent
            if not (char:GetAttribute("Dead") == true) then
                local isOccluded = false
                if Config.AIM_OCCLUSION_CHECK then
                    if Utils and Utils.areAllHitboxesOccluded then
                        isOccluded = Utils.areAllHitboxesOccluded(char)
                    end
                end

                if not isOccluded then
                    local success, result = pcall(function()
                        local ignoreList = GetRayIgnore()
                        local cam = Workspace.CurrentCamera
                        local vpCenter = cam.ViewportSize * 0.5
                        local vpRay = cam:ViewportPointToRay(vpCenter.X, vpCenter.Y)
                        local Origin = vpRay.Origin

                        local targetPos = targetPart.Position
                        local LookVector = (targetPos - Origin).Unit
                        local totalDistance = (targetPos - Origin).Magnitude
                        local range = math.max((self.Properties and self.Properties.Range) or 500, totalDistance + 50)
                        local penetration = (self.Properties and self.Properties.Penetration) or 0

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
                        notifyHit(result)
                        return result
                    end
                end
            end
        end

        local fallbackResult
        if _G.__originalPerformRaycast and _G.__originalPerformRaycast ~= silentAimPerformRaycast then
            fallbackResult = _G.__originalPerformRaycast(self, spread)
        else
            fallbackResult = nativeRaycastWithSpread(self, spread)
        end

        notifyHit(fallbackResult)

        return fallbackResult
    end

    BulletModule._performRaycast = silentAimPerformRaycast
end

function SilentAim.cleanup()
    if _G.__originalPerformRaycast then
        pcall(function() BulletModule._performRaycast = _G.__originalPerformRaycast end)
    end
    _G.__originalPerformRaycast = nil
end

return SilentAim
