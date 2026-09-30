-- damage calculations
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local DamageEngine = {}

local WeaponsDB = ReplicatedStorage:FindFirstChild("Database")
if WeaponsDB then WeaponsDB = WeaponsDB:FindFirstChild("Custom") end
if WeaponsDB then WeaponsDB = WeaponsDB:FindFirstChild("Weapons") end

local weaponCache = {}

function DamageEngine.getWeaponConfig(weaponName)
    if not WeaponsDB or not weaponName then return nil end
    if weaponCache[weaponName] then return weaponCache[weaponName] end
    local mod = WeaponsDB:FindFirstChild(weaponName)
    if not mod then return nil end
    local ok, cfg = pcall(require, mod)
    if ok and cfg then
        weaponCache[weaponName] = cfg
        return cfg
    end
    return nil
end

local cachedCurrentEquippedRaw = nil
local cachedParsedWeaponName = nil

function DamageEngine.getCurrentWeapon()
    local attr = LocalPlayer:GetAttribute("CurrentEquipped")
    if not attr then return nil end

    if attr == cachedCurrentEquippedRaw then
        return cachedParsedWeaponName
    end

    cachedCurrentEquippedRaw = attr

    if typeof(attr) == "string" then
        local ok, parsed = pcall(HttpService.JSONDecode, HttpService, attr)
        if ok and parsed and parsed.Name then
            cachedParsedWeaponName = parsed.Name
            return cachedParsedWeaponName
        end
    elseif typeof(attr) == "table" and attr.Name then
        cachedParsedWeaponName = attr.Name
        return cachedParsedWeaponName
    end

    cachedParsedWeaponName = nil
    return nil
end

function DamageEngine.getPlayerArmor(player)
    if not player then return "None" end
    local armorAttr = player:GetAttribute("Armor")
    if not armorAttr then return "None" end

    if typeof(armorAttr) == "string" then
        if armorAttr:find("Helmet") then
            return "Kevlar + Helmet"
        elseif armorAttr:find("Kevlar") then
            return "Kevlar"
        end
        local ok, parsed = pcall(HttpService.JSONDecode, HttpService, armorAttr)
        if ok and parsed and parsed.Type then
            return parsed.Type
        end
    elseif typeof(armorAttr) == "table" and armorAttr.Type then
        return armorAttr.Type
    end
    return "None"
end

function DamageEngine.calcDamage(weaponCfg, zone, distance, armorType, falloffRef)
    local baseDmg = weaponCfg.DamagePerPart and weaponCfg.DamagePerPart[zone]
    if not baseDmg then return 0 end

    falloffRef = falloffRef or 500
    local rangeMod = weaponCfg.RangeModifier or 1
    local rawDmg = baseDmg * (rangeMod ^ (distance / falloffRef))

    local hasArmor = (armorType == "Kevlar" or armorType == "Kevlar + Helmet")
    local hasHelmet = (armorType == "Kevlar + Helmet")

    local armorCoversZone = false
    if zone == "Head" then
        armorCoversZone = hasHelmet
    elseif zone == "Torso" or zone == "Arms" then
        armorCoversZone = hasArmor
    end

    if armorCoversZone then
        local armorPen = weaponCfg.ArmorPenetration or 1
        rawDmg = rawDmg * armorPen
    end

    return math.floor(rawDmg)
end

-- lethal part solver
function DamageEngine.getOptimalTargetPart(weaponCfg, targetChar, targetPlayer, myDistance, hp, falloffRef)
    if not weaponCfg or not weaponCfg.DamagePerPart then
        return "Head"
    end

    local armorType = DamageEngine.getPlayerArmor(targetPlayer)
    local bulletsPerShot = weaponCfg.BulletsPerShot or 1

    local pelletHeadDmg = DamageEngine.calcDamage(weaponCfg, "Head", myDistance, armorType, falloffRef)
    local pelletBodyDmg = DamageEngine.calcDamage(weaponCfg, "Torso", myDistance, armorType, falloffRef)

    local totalBodyBurst
    if bulletsPerShot > 1 then
        totalBodyBurst = pelletBodyDmg * math.floor(bulletsPerShot * 0.75)
    else
        totalBodyBurst = pelletBodyDmg
    end

    if totalBodyBurst >= hp then
        return "Torso"
    else
        return "Head"
    end
end

return DamageEngine
