-- wallbang

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Wallbang = {
    Installed = false,
    Config = nil,
}

local origSend = nil
local localPlayer = Players.LocalPlayer

function Wallbang.init(Config)
    Wallbang.Config = Config
    if Wallbang.Installed then return end
    Wallbang.Installed = true

    local Remotes = require(ReplicatedStorage.Database.Security.Remotes)
    local ShootWeapon = Remotes.Inventory.ShootWeapon
    if not ShootWeapon then return end

    if not _G.__origShootWeaponSend then
        _G.__origShootWeaponSend = ShootWeapon.Send
    end
    origSend = _G.__origShootWeaponSend

    ShootWeapon.Send = function(packet)
        if Config.WALLBANG_ENABLED and packet and packet.Bullets then
            local targetPart = Config.CurrentTargetPart
            if targetPart and targetPart.Parent and targetPart:IsDescendantOf(Workspace) then
                local char = targetPart.Parent
                if not (char:GetAttribute("Dead") == true) and char ~= localPlayer.Character then
                    for _, bullet in ipairs(packet.Bullets) do
                        local origin = bullet.Origin
                        local targetPos = targetPart.Position
                        local direction = (targetPos - origin).Unit
                        local distToTarget = (targetPos - origin).Magnitude

                        bullet.Direction = direction

                        local entryNormal = -direction
                        bullet.Hits = {
                            {
                                Normal = entryNormal,
                                Position = targetPos + entryNormal * 0.5,
                                Instance = targetPart,
                                Distance = distToTarget,
                                Exit = false,
                                Material = "Plastic",
                            },
                            {
                                Normal = direction,
                                Position = targetPos - entryNormal * 0.5,
                                Instance = targetPart,
                                Distance = 1.0,
                                Exit = true,
                                Material = "Plastic",
                            },
                        }

                        bullet.Distance = nil
                    end
                end
            end
        end

        return origSend(packet)
    end
end

function Wallbang.cleanup()
    if origSend then
        pcall(function()
            local Remotes = require(ReplicatedStorage.Database.Security.Remotes)
            Remotes.Inventory.ShootWeapon.Send = origSend
        end)
    end
    if _G.__origShootWeaponSend then
        _G.__origShootWeaponSend = nil
    end
    origSend = nil
    Wallbang.Installed = false
end

return Wallbang
