-- glove changer
-- The game asks SkinsLib.GetGloves(gloveName, skin, float) whenever it has to
-- build the glove model, so hooking that one call is enough to swap the model
-- everywhere it is used. On top of that the live inventory glove item is mutated
-- and the currently equipped viewmodel is rebuilt, mirroring the reference
-- source, so the change shows up without needing a re-equip.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

local GloveChanger = {
    Initialized = false
}

local storedConfig = nil
local SkinsLib = nil
local originalGetGloves = nil

-- fallback list, taken straight from the game dump
local KNOWN_GLOVES = {
    "Hand Wraps", "T Glove", "CT Glove",
    "Driver Gloves", "Operator Gloves", "Sports Gloves"
}

local function safeRequire(module)
    local previous = getthreadidentity and getthreadidentity()

    if setthreadidentity then pcall(setthreadidentity, 2) end

    local ok, res = pcall(require, module)

    if setthreadidentity and previous then pcall(setthreadidentity, previous) end

    if ok and res ~= nil then return res end

    local ok2, res2 = pcall(require, module)
    if ok2 and res2 ~= nil then return res2 end

    return nil
end

function GloveChanger.isGlove(name)
    if type(name) ~= "string" then return false end
    local lower = name:lower()

    if lower == "hand wraps" then return true end

    for _, glove in ipairs(KNOWN_GLOVES) do
        if lower == glove:lower() then return true end
    end

    return lower:find("glove", 1, true) ~= nil
end

function GloveChanger.getGloveModels()
    return KNOWN_GLOVES
end

local function isEnabled()
    return storedConfig and storedConfig.GLOVE_CHANGER_ENABLED == true
end

-- the glove entry inside the live loadout table
local function getActiveLoadout()
    local controller = nil
    pcall(function()
        controller = require(ReplicatedStorage.Controllers.InventoryController)
    end)

    if not controller then return nil end

    local getUp = getupvalues or debug.getupvalues
    if type(getUp) ~= "function" then return nil end

    for _, fnName in ipairs({ "getCurrentEquipped", "getCurrentInventory", "getInventorySlot" }) do
        local fn = controller[fnName]

        if type(fn) == "function" then
            local ok, upvalues = pcall(getUp, fn)

            if ok and type(upvalues) == "table" then
                for _, upvalue in pairs(upvalues) do
                    if type(upvalue) == "table" and rawget(upvalue, "Inventory") then
                        return upvalue, controller
                    end
                end
            end
        end
    end

    return nil
end

-- rebuilds the gloves hanging off the equipped viewmodel
local function refreshEquippedGloves(loadout, model, skin)
    local equipped = loadout and loadout.CurrentEquipped
    local viewmodel = equipped and equipped.Viewmodel

    if (not viewmodel) or (not SkinsLib) then return end

    pcall(function()
        if viewmodel.Gloves then
            viewmodel.Gloves:Destroy()
            viewmodel.Gloves = nil
        end
    end)

    pcall(function()
        local newGloves = SkinsLib.GetGloves(model, skin, 0)

        if newGloves then
            if viewmodel.Model then
                newGloves.Parent = viewmodel.Model
            end

            viewmodel.Gloves = newGloves
        end
    end)
end

function GloveChanger.applyLive()
    if not isEnabled() then return end

    local loadout, controller = getActiveLoadout()
    if (not loadout) or (not loadout.Inventory) then return end

    local model = storedConfig.GLOVE_MODEL
    if type(model) ~= "string" or model == "" or model == "Default" then return end

    local skin = storedConfig.GLOVE_SKIN or "Stock"

    local slot = loadout.Inventory[7] or loadout.Inventory[6] or loadout.Inventory["Gloves"]
    if (not slot) or (not slot._items) or (not slot._items[1]) then return end

    local item = slot._items[1]

    if item.Name == model and item.Skin == skin then return end

    pcall(function()
        item.Name = model
        item.Skin = skin
    end)

    pcall(function() refreshEquippedGloves(loadout, model, skin) end)

    pcall(function()
        if controller and controller.OnInventoryChanged then
            controller.OnInventoryChanged:Fire(loadout.Inventory)
        end
    end)
end

function GloveChanger.init(Config)
    if GloveChanger.Initialized then return end
    GloveChanger.Initialized = true

    storedConfig = Config

    pcall(function()
        SkinsLib = safeRequire(ReplicatedStorage.Database.Components.Libraries.Skins)
    end)

    if (type(SkinsLib) ~= "table") or (type(SkinsLib.GetGloves) ~= "function") then
        return
    end

    originalGetGloves = SkinsLib.GetGloves

    SkinsLib.GetGloves = function(name, skin, float)
        if isEnabled() and GloveChanger.isGlove(name) then
            local model = storedConfig.GLOVE_MODEL

            if type(model) == "string" and model ~= "" and model ~= "Default" then
                local ok, res = pcall(originalGetGloves, model, storedConfig.GLOVE_SKIN or "Stock", float)
                if ok and res then return res end
            end
        end

        return originalGetGloves(name, skin, float)
    end
end

function GloveChanger.cleanup()
    if SkinsLib and originalGetGloves then
        pcall(function()
            SkinsLib.GetGloves = originalGetGloves
        end)
    end

    originalGetGloves = nil
    SkinsLib = nil
    storedConfig = nil
    GloveChanger.Initialized = false
end

return GloveChanger
