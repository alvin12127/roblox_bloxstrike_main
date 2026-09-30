-- silent aim and recoil hook
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

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

function SilentAim.init(Config, Utils)
    if not _G.__originalPerformRaycast then
        _G.__originalPerformRaycast = BulletModule._performRaycast
    end

    -- bullet raycast redirection
    local function silentAimPerformRaycast(self, spread)
        local targetPart = Config.CurrentTargetPart
        local active = (type(Config.isSilentAimActive) == "function") and Config.isSilentAimActive() or (Config.SILENT_AIM_ENABLED ~= false)

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
                        return result
                    end
                end
            end
        end

        if _G.__originalPerformRaycast and _G.__originalPerformRaycast ~= silentAimPerformRaycast then
            return _G.__originalPerformRaycast(self, spread)
        end
        return nativeRaycastWithSpread(self, spread)
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
