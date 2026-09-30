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

-- patch database configs
local function patchDatabaseConfig(cfg, name, Config)
    if not cfg or type(cfg) ~= 'table' then return end
    if isreadonly(cfg) then setreadonly(cfg, false) end

    local orig = WeaponEngine._originalConfigs[name] or {}

    -- custom rpm
    if Config.CUSTOM_RPM_ENABLED and Config.CUSTOM_RPM_VALUE and Config.CUSTOM_RPM_VALUE > 0 then
        cfg.FireRate = 60 / Config.CUSTOM_RPM_VALUE
    elseif orig.FireRate ~= nil then
        cfg.FireRate = orig.FireRate
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
            if Config.CUSTOM_RPM_ENABLED and Config.CUSTOM_RPM_VALUE and Config.CUSTOM_RPM_VALUE > 0 then
                cfg.FireModes.Primary.FireRate = 60 / Config.CUSTOM_RPM_VALUE
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
            if Config.CUSTOM_RPM_ENABLED and Config.CUSTOM_RPM_VALUE and Config.CUSTOM_RPM_VALUE > 0 then
                cfg.FireModes.Secondary.FireRate = 60 / Config.CUSTOM_RPM_VALUE
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

        local orig = WeaponEngine._originalConfigs[item.Name] or {}

        if Config.CUSTOM_RPM_ENABLED and Config.CUSTOM_RPM_VALUE and Config.CUSTOM_RPM_VALUE > 0 then
            props.FireRate = 60 / Config.CUSTOM_RPM_VALUE
        elseif orig.FireRate ~= nil then
            props.FireRate = orig.FireRate
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
                if Config.CUSTOM_RPM_ENABLED and Config.CUSTOM_RPM_VALUE and Config.CUSTOM_RPM_VALUE > 0 then
                    props.FireModes.Primary.FireRate = 60 / Config.CUSTOM_RPM_VALUE
                end
                if Config.FORCE_FULL_AUTO then
                    props.FireModes.Primary.HoldRepeat = true
                end
                table.freeze(props.FireModes.Primary)
            end
            if type(props.FireModes.Secondary) == 'table' then
                if isreadonly(props.FireModes.Secondary) then setreadonly(props.FireModes.Secondary, false) end
                if Config.CUSTOM_RPM_ENABLED and Config.CUSTOM_RPM_VALUE and Config.CUSTOM_RPM_VALUE > 0 then
                    props.FireModes.Secondary.FireRate = 60 / Config.CUSTOM_RPM_VALUE
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
