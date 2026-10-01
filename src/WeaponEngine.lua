-- weapon engine
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local WeaponsFolder = ReplicatedStorage:WaitForChild('Database'):WaitForChild('Custom'):WaitForChild('Weapons')

local WeaponMod = nil
pcall(function()
    WeaponMod = require(ReplicatedStorage:WaitForChild('Components'):WaitForChild('Weapon'))
end)

local InventoryController = nil
pcall(function()
    InventoryController = require(ReplicatedStorage:WaitForChild('Controllers'):WaitForChild('InventoryController'))
end)

local WeaponEngine = {
    Initialized = false,
    LoopActive = false,
    Connections = {},
    _originalConfigs = {}
}

local function cloneTable(t)
    if type(t) ~= 'table' then return t end
    local copy = {}
    for k, v in pairs(t) do
        if type(v) == 'table' then
            copy[k] = cloneTable(v)
        else
            copy[k] = v
        end
    end
    return copy
end

-- known recoil / spread field names used by the weapon database.
-- The whole config is cloned into _originalConfigs on init, so anything zeroed
-- here is restored byte for byte by cleanup().
local RECOIL_KEYS = {
    recoil = true, recoilamount = true, verticalrecoil = true, horizontalrecoil = true,
    recoilvertical = true, recoilhorizontal = true, recoilrecovery = true, recoilseed = true,
    viewkick = true, viewkickamount = true, aimpunch = true, punch = true, kick = true,
    kickamount = true, camerarecoil = true, recoilpitch = true, recoilyaw = true
}

local SPREAD_KEYS = {
    spread = true, spreadmin = true, spreadmax = true, basespread = true,
    maxspread = true, minspread = true, spreadrecovery = true, spreadpershot = true,
    bloom = true, bloompershot = true, spreadincrease = true, spreaddecrease = true,
    spreadfactor = true, accuracy = true, inaccuracy = true
}

-- Values that control where a bullet actually travels. Zeroing any of these
-- changes hit registration, which is what made silent aim start missing once the
-- gun mods were switched on: the recoil/spread pass walks the whole config table
-- and a badly named field would have been caught in it.
local BALLISTIC_KEYS = {
    -- every key must be plain lower case: the lookup is done with
    -- tostring(key):lower(), and Lua table keys are case sensitive, so a camel
    -- case entry here silently fails to protect its field
    range = true, penetration = true, bulletspershot = true,
    damage = true, damageperpart = true, rangemodifier = true,
    armorpenetration = true, velocity = true, speed = true,
    headshotmultiplier = true, falloff = true,
    firerate = true, automatic = true, headmultiplier = true
}

-- 3000 rpm is already beyond what the target scan can keep up with; going lower
-- just makes bullets spawn faster than CurrentTargetPart is refreshed, which reads
-- as silent aim "missing".
local MIN_FIRE_RATE = 0.02

local function zeroAllNumbers(tbl)
    if type(tbl) ~= 'table' then return end
    if isreadonly(tbl) then setreadonly(tbl, false) end

    for key, value in pairs(tbl) do
        if type(value) == 'number' then
            if not BALLISTIC_KEYS[tostring(key):lower()] then
                tbl[key] = 0
            end
        elseif type(value) == 'table' then
            zeroAllNumbers(value)
        end
    end
end

local function patchRecoilSpread(tbl, Config, depth)
    depth = depth or 0
    if type(tbl) ~= 'table' or depth > 4 then return end
    if isreadonly(tbl) then setreadonly(tbl, false) end

    local removeRecoil = Config.NO_RECOIL == true
    local removeSpread = Config.NO_SPREAD == true
    if (not removeRecoil) and (not removeSpread) then return end

    for key, value in pairs(tbl) do
        local lower = tostring(key):lower()
        local matched = (removeRecoil and RECOIL_KEYS[lower]) or (removeSpread and SPREAD_KEYS[lower])

        if matched and not BALLISTIC_KEYS[lower] then
            if type(value) == 'number' then
                tbl[key] = 0
            elseif type(value) == 'table' then
                zeroAllNumbers(value)
            end
        elseif type(value) == 'table' then
            patchRecoilSpread(value, Config, depth + 1)
        end
    end
end

-- belt and braces: put the original ballistic numbers back after patching, so a
-- stray match can never survive into the actual shot
local function restoreBallistics(cfg, orig)
    if type(cfg) ~= 'table' or type(orig) ~= 'table' then return end

    for origKey, origValue in pairs(orig) do
        if BALLISTIC_KEYS[tostring(origKey):lower()] then
            if cfg[origKey] ~= origValue then
                pcall(function() cfg[origKey] = origValue end)
            end
        end
    end
end

-- shared fire rate resolution, clamped so it can never run away
local function resolveFireRate(Config, orig)
    local rate = nil

    if Config.CUSTOM_RPM_ENABLED and Config.CUSTOM_RPM_VALUE and Config.CUSTOM_RPM_VALUE > 0 then
        rate = 60 / Config.CUSTOM_RPM_VALUE
    elseif orig and orig.FireRate ~= nil then
        rate = orig.FireRate
    end

    if type(rate) ~= 'number' then return nil end

    return math.max(rate, MIN_FIRE_RATE)
end

-- patch database configs
local function patchDatabaseConfig(cfg, name, Config)
    if not cfg or type(cfg) ~= 'table' then return end
    if isreadonly(cfg) then setreadonly(cfg, false) end

    local orig = WeaponEngine._originalConfigs[name] or {}

    -- recoil and spread removal, ballistics put straight back afterwards
    patchRecoilSpread(cfg, Config)
    restoreBallistics(cfg, orig)

    -- custom rpm, clamped so bullets cannot outpace the target scan
    local fireRate = resolveFireRate(Config, orig)
    if fireRate then
        cfg.FireRate = fireRate
    end

    -- full auto
    if Config.FORCE_FULL_AUTO then
        cfg.Automatic = true
    elseif orig.Automatic ~= nil then
        cfg.Automatic = orig.Automatic
    end

    -- fire modes
    if type(cfg.FireModes) == 'table' then
        if isreadonly(cfg.FireModes) then setreadonly(cfg.FireModes, false) end
        if type(cfg.FireModes.Primary) == 'table' then
            if isreadonly(cfg.FireModes.Primary) then setreadonly(cfg.FireModes.Primary, false) end
            -- same clamped value as the top level field, so the fire modes can
            -- never run unclamped either
            if fireRate then
                cfg.FireModes.Primary.FireRate = fireRate
            elseif orig.FireModes and orig.FireModes.Primary and orig.FireModes.Primary.FireRate ~= nil then
                cfg.FireModes.Primary.FireRate = orig.FireModes.Primary.FireRate
            end
            if Config.FORCE_FULL_AUTO then
                cfg.FireModes.Primary.HoldRepeat = true
            elseif orig.FireModes and orig.FireModes.Primary and orig.FireModes.Primary.HoldRepeat ~= nil then
                cfg.FireModes.Primary.HoldRepeat = orig.FireModes.Primary.HoldRepeat
            end
            table.freeze(cfg.FireModes.Primary)
        end
        if type(cfg.FireModes.Secondary) == 'table' then
            if isreadonly(cfg.FireModes.Secondary) then setreadonly(cfg.FireModes.Secondary, false) end
            if fireRate then
                cfg.FireModes.Secondary.FireRate = fireRate
            elseif orig.FireModes and orig.FireModes.Secondary and orig.FireModes.Secondary.FireRate ~= nil then
                cfg.FireModes.Secondary.FireRate = orig.FireModes.Secondary.FireRate
            end
            if Config.FORCE_FULL_AUTO then
                cfg.FireModes.Secondary.HoldRepeat = true
            elseif orig.FireModes and orig.FireModes.Secondary and orig.FireModes.Secondary.HoldRepeat ~= nil then
                cfg.FireModes.Secondary.HoldRepeat = orig.FireModes.Secondary.HoldRepeat
            end
            table.freeze(cfg.FireModes.Secondary)
        end
        table.freeze(cfg.FireModes)
    end

    table.freeze(cfg)
end

-- patch live item
local function patchLiveItem(item, Config)
    if not item or type(item) ~= 'table' then return end

    local props = item.Properties
    if props and type(props) == 'table' then
        if isreadonly(props) then setreadonly(props, false) end

        -- keep a backup before mutating so cleanup can restore it
        if not WeaponEngine._originalConfigs[item.Name] then
            WeaponEngine._originalConfigs[item.Name] = cloneTable(props)
        end

        local orig = WeaponEngine._originalConfigs[item.Name] or {}

        patchRecoilSpread(props, Config)
        restoreBallistics(props, orig)

        local fireRate = resolveFireRate(Config, orig)
        if fireRate then
            props.FireRate = fireRate
        end

        if Config.FORCE_FULL_AUTO then
            props.Automatic = true
        elseif orig.Automatic ~= nil then
            props.Automatic = orig.Automatic
        end

        if type(props.FireModes) == 'table' then
            if isreadonly(props.FireModes) then setreadonly(props.FireModes, false) end
            if type(props.FireModes.Primary) == 'table' then
                if isreadonly(props.FireModes.Primary) then setreadonly(props.FireModes.Primary, false) end
                if fireRate then
                    props.FireModes.Primary.FireRate = fireRate
                end
                if Config.FORCE_FULL_AUTO then
                    props.FireModes.Primary.HoldRepeat = true
                end
                table.freeze(props.FireModes.Primary)
            end
            if type(props.FireModes.Secondary) == 'table' then
                if isreadonly(props.FireModes.Secondary) then setreadonly(props.FireModes.Secondary, false) end
                if fireRate then
                    props.FireModes.Secondary.FireRate = fireRate
                end
                if Config.FORCE_FULL_AUTO then
                    props.FireModes.Secondary.HoldRepeat = true
                end
                table.freeze(props.FireModes.Secondary)
            end
            table.freeze(props.FireModes)
        end

        table.freeze(props)
    end
end

function WeaponEngine.sync(Config)
    if not Config then return end

    -- db modules
    for _, mod in ipairs(WeaponsFolder:GetChildren()) do
        if mod:IsA('ModuleScript') then
            local ok, cfg = pcall(require, mod)
            if ok and type(cfg) == 'table' then
                patchDatabaseConfig(cfg, mod.Name, Config)
            end
        end
    end

    -- shoot upvalues
    if WeaponMod and WeaponMod.shoot and getupvalues then
        local ok, upvals = pcall(getupvalues, WeaponMod.shoot)
        if ok and type(upvals) == 'table' and type(upvals[5]) == 'table' then
            for name, w in pairs(upvals[5]) do
                if type(w) == 'table' then
                    patchDatabaseConfig(w, name, Config)
                end
            end
        end
    end

    -- inventory loadout
    if InventoryController and debug.getupvalues then
        local ok, ups = pcall(debug.getupvalues, InventoryController.getCurrentInventory)
        if ok and ups and ups[1] then
            local loadout = ups[1]
            if loadout.CurrentEquipped then
                patchLiveItem(loadout.CurrentEquipped, Config)
            end
            if loadout.Inventory then
                for _, slotData in pairs(loadout.Inventory) do
                    if slotData._items then
                        for _, item in ipairs(slotData._items) do
                            patchLiveItem(item, Config)
                        end
                    end
                end
            end
        end
    end
end

function WeaponEngine.init(Config)
    if WeaponEngine.Initialized then return end
    WeaponEngine.Initialized = true

    -- cache original configs
    for _, mod in ipairs(WeaponsFolder:GetChildren()) do
        if mod:IsA('ModuleScript') then
            local ok, cfg = pcall(require, mod)
            if ok and type(cfg) == 'table' and not WeaponEngine._originalConfigs[mod.Name] then
                WeaponEngine._originalConfigs[mod.Name] = cloneTable(cfg)
            end
        end
    end

    -- equip listener
    if InventoryController and InventoryController.OnInventoryItemEquipped then
        local conn = InventoryController.OnInventoryItemEquipped:Connect(function(slot, item)
            if type(item) == 'table' then
                patchLiveItem(item, Config)
            end
            pcall(WeaponEngine.sync, Config)
        end)
        table.insert(WeaponEngine.Connections, conn)
    end

    local charConn = game:GetService('Players').LocalPlayer.CharacterAdded:Connect(function()
        task.delay(0.25, function()
            pcall(WeaponEngine.sync, Config)
        end)
    end)
    table.insert(WeaponEngine.Connections, charConn)

    -- initial sync
    WeaponEngine.sync(Config)
end

function WeaponEngine.cleanup()
    WeaponEngine.LoopActive = false
    for _, conn in ipairs(WeaponEngine.Connections) do
        pcall(function() conn:Disconnect() end)
    end
    WeaponEngine.Connections = {}

    -- restore original configs
    for name, orig in pairs(WeaponEngine._originalConfigs) do
        local mod = WeaponsFolder:FindFirstChild(name)
        if mod and mod:IsA('ModuleScript') then
            local ok, cfg = pcall(require, mod)
            if ok and type(cfg) == 'table' then
                if isreadonly(cfg) then setreadonly(cfg, false) end
                for k, v in pairs(orig) do
                    if type(v) == 'table' then
                        cfg[k] = cloneTable(v)
                    else
                        cfg[k] = v
                    end
                end
                table.freeze(cfg)
            end
        end
    end

    WeaponEngine.Initialized = false
end

return WeaponEngine
