-- ui manager
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

local UIManager = {
    Initialized = false,
    Library = nil,
    Window = nil,
    Connections = {}
}

function UIManager.init(Config, Library, SkinChanger, WeaponEngine, unloadCallback)
    if type(WeaponEngine) == "function" and unloadCallback == nil then
        unloadCallback = WeaponEngine
        WeaponEngine = nil
    end

    if UIManager.Initialized then return end
    UIManager.Initialized = true
    UIManager.Library = Library

    -- apply theme
    if Config.UI_THEME then
        for prop, val in pairs(Config.UI_THEME) do
            if Library[prop] ~= nil then
                Library[prop] = val
            end
        end
    end

    -- auto save debounce
    local saveDebounce = nil
    local function queueAutoSave()
        if saveDebounce then
            task.cancel(saveDebounce)
        end
        saveDebounce = task.delay(0.35, function()
            Config.save()
            saveDebounce = nil
        end)
    end

    local function updateSetting(key, newVal)
        if Config[key] ~= newVal then
            Config[key] = newVal
            queueAutoSave()
        end
    end

    -- window
    local Window = Library:CreateWindow({
        Title = "@Discord_alvin6974. / Bloxstrike / v2.5",
        Center = true,
        AutoShow = (Config.MENU_OPEN ~= false),
        TabPadding = 6,
        MenuFadeTime = 0.2,
        Size = UDim2.fromOffset(Config.WINDOW_SIZE_X or 440, Config.WINDOW_SIZE_Y or 210),
        ResizeCallback = function(w, h)
            if Config.WINDOW_SIZE_X ~= w or Config.WINDOW_SIZE_Y ~= h then
                Config.WINDOW_SIZE_X = w
                Config.WINDOW_SIZE_Y = h
                queueAutoSave()
            end
        end
    })
    UIManager.Window = Window

    local Tabs = {
        Aim = Window:AddTab("Aim"),
        Weapons = Window:AddTab("Weapons"),
        Visuals = Window:AddTab("Visuals"),
        Movement = Window:AddTab("Movement"),
        Skins = Window:AddTab("Skins"),
        Settings = Window:AddTab("Settings")
    }

    -- aim tab
    local AimMain = Tabs.Aim:AddLeftGroupbox("Silent Aim and Targeting")

    AimMain:AddToggle("SilentAim", {
        Text = "Silent aim",
        Default = (Config.SILENT_AIM_ENABLED ~= false),
        Tooltip = "Redirects bullets directly to optimal enemy hitbox within FOV cone",
        Callback = function(Value)
            updateSetting("SILENT_AIM_ENABLED", Value)
        end
    })

    AimMain:AddToggle("KeepLock", {
        Text = "Keep target lock",
        Default = (Config.KEEP_TARGET_LOCK ~= false),
        Tooltip = "Maintains lock on current target while firing",
        Callback = function(Value)
            updateSetting("KEEP_TARGET_LOCK", Value)
        end
    })

    AimMain:AddToggle("AimOcclusionCheck", {
        Text = "Occlusion check",
        Default = (Config.AIM_OCCLUSION_CHECK == true),
        Tooltip = "Prevents bullet redirection if all hitboxes of a target are occluded behind walls",
        Callback = function(Value)
            updateSetting("AIM_OCCLUSION_CHECK", Value)
        end
    })

    AimMain:AddDropdown("TargetPriority", {
        Values = { "Auto", "Head", "Torso", "Random" },
        Default = Config.TARGET_PRIORITY or "Auto",
        Multi = false,
        Text = "Target priority",
        Tooltip = "Auto: Lethal damage calculation and occlusion scanner\nHead: Strictly headshots\nTorso: Upper and lower torso\nRandom: Random visible hitbox",
        Callback = function(Value)
            updateSetting("TARGET_PRIORITY", Value)
        end
    })

    -- weapons tab
    local WeaponFire = Tabs.Weapons:AddLeftGroupbox("Fire Rate & Trigger")
    local WeaponPen = Tabs.Weapons:AddRightGroupbox("Penetration & Wallbang")

    WeaponFire:AddToggle("CustomRpm", {
        Text = "Custom fire rate (RPM)",
        Default = (Config.CUSTOM_RPM_ENABLED == true),
        Tooltip = "Overrides the fire rate for all equipped and database weapons",
        Callback = function(Value)
            updateSetting("CUSTOM_RPM_ENABLED", Value)
            if WeaponEngine and WeaponEngine.sync then WeaponEngine.sync(Config) end
        end
    })

    WeaponFire:AddSlider("RpmSlider", {
        Text = "Fire rate (RPM)",
        Default = Config.CUSTOM_RPM_VALUE or 600,
        Min = 60,
        Max = 3000,
        Rounding = 0,
        Compact = false,
        Suffix = " RPM",
        Tooltip = "Rounds per minute. Standard rifles: ~600-800 RPM. Rapid fire: 1500-3000 RPM.",
        Callback = function(Value)
            updateSetting("CUSTOM_RPM_VALUE", Value)
            if WeaponEngine and WeaponEngine.sync then WeaponEngine.sync(Config) end
        end
    })

    WeaponFire:AddToggle("ForceFullAuto", {
        Text = "Force full auto",
        Default = (Config.FORCE_FULL_AUTO == true),
        Tooltip = "Converts all semi-automatic pistols, shotguns, and snipers to full-automatic",
        Callback = function(Value)
            updateSetting("FORCE_FULL_AUTO", Value)
            if WeaponEngine and WeaponEngine.sync then WeaponEngine.sync(Config) end
        end
    })

    WeaponPen:AddToggle("Wallbang", {
        Text = "Infinite wallbang",
        Default = (Config.WALLBANG_ENABLED == true),
        Tooltip = "Fabricates bullet hits through any wall. Requires silent aim to lock a target.",
        Callback = function(Value)
            updateSetting("WALLBANG_ENABLED", Value)
        end
    })

    WeaponPen:AddButton({
        Text = "Set all default",
        Func = function()
            if Toggles.CustomRpm then Toggles.CustomRpm:SetValue(false) end
            if Options.RpmSlider then Options.RpmSlider:SetValue(1491) end
            if Toggles.ForceFullAuto then Toggles.ForceFullAuto:SetValue(false) end
            if Toggles.Wallbang then Toggles.Wallbang:SetValue(false) end
            updateSetting("CUSTOM_RPM_ENABLED", false)
            updateSetting("CUSTOM_RPM_VALUE", 1491)
            updateSetting("FORCE_FULL_AUTO", false)
            updateSetting("WALLBANG_ENABLED", false)
            if WeaponEngine and WeaponEngine.sync then WeaponEngine.sync(Config) end
            queueAutoSave()
            Library:Notify("Weapon modifiers reset to defaults", 2)
        end,
        DoubleClick = false,
        Tooltip = "Resets all weapon modifiers (RPM, Full Auto, Wallbang) to factory defaults"
    })

    -- visuals tab
    local EspMain = Tabs.Visuals:AddLeftGroupbox("ESP Elements")
    local VisualSettings = Tabs.Visuals:AddRightGroupbox("FOV & Utilities")

    EspMain:AddToggle("EspMaster", {
        Text = "Enable ESP",
        Default = (Config.ESP_ENABLED ~= false),
        Tooltip = "Master switch to enable or disable all visual ESP features",
        Callback = function(Value)
            updateSetting("ESP_ENABLED", Value)
        end
    })

    EspMain:AddToggle("SkeletonEsp", {
        Text = "Skeleton ESP",
        Default = (Config.SKELETON_ENABLED ~= false),
        Tooltip = "Renders 3D bone skeletons and health bars on characters",
        Callback = function(Value)
            updateSetting("SKELETON_ENABLED", Value)
        end
    })

    EspMain:AddToggle("ViewAngle", {
        Text = "View angle",
        Default = (Config.VIEWANGLE_ENABLED ~= false),
        Tooltip = "Renders head look direction indicator ray",
        Callback = function(Value)
            updateSetting("VIEWANGLE_ENABLED", Value)
        end
    })

    EspMain:AddToggle("OffscreenArrows", {
        Text = "Offscreen arrows",
        Default = (Config.OFFSCREEN_ARROWS ~= false),
        Tooltip = "Directional triangle pointers for out-of-view enemies with distance fade",
        Callback = function(Value)
            updateSetting("OFFSCREEN_ARROWS", Value)
        end
    })

    EspMain:AddToggle("TargetPartHl", {
        Text = "Visualize target part",
        Default = (Config.BODYPART_TARGET_HL ~= false),
        Tooltip = "Highlights active targeted limb with yellow outline",
        Callback = function(Value)
            updateSetting("BODYPART_TARGET_HL", Value)
        end
    })

    EspMain:AddToggle("DisableTeammates", {
        Text = "Disable teammates",
        Default = (Config.DISABLE_TEAMMATES == true),
        Tooltip = "Hides ESP and offscreen arrows for friendly teammates",
        Callback = function(Value)
            updateSetting("DISABLE_TEAMMATES", Value)
        end
    })

    EspMain:AddToggle("OcclusionCheck", {
        Text = "Occlusion check",
        Default = (Config.OCCLUSION_CHECK_ENABLED ~= false),
        Tooltip = "Dims skeleton bone color when character is behind walls",
        Callback = function(Value)
            updateSetting("OCCLUSION_CHECK_ENABLED", Value)
        end
    })

    EspMain:AddToggle("SpectatorChecker", {
        Text = "Spectator counter",
        Default = (Config.SPECTATE_CHECKER_ENABLED ~= false),
        Tooltip = "HUD widget displaying players spectating your camera",
        Callback = function(Value)
            updateSetting("SPECTATE_CHECKER_ENABLED", Value)
        end
    })

    VisualSettings:AddToggle("ShowFov", {
        Text = "Show FOV circle",
        Default = (Config.FOV_CIRCLE_ENABLED ~= false),
        Tooltip = "Renders screen-center FOV boundary",
        Callback = function(Value)
            updateSetting("FOV_CIRCLE_ENABLED", Value)
        end
    })

    VisualSettings:AddSlider("FovAngle", {
        Text = "FOV angle",
        Default = Config.FOV_DEG or 30,
        Min = 1,
        Max = 180,
        Rounding = 0,
        Compact = false,
        Suffix = "°",
        Callback = function(Value)
            updateSetting("FOV_DEG", Value)
        end
    })

    VisualSettings:AddSlider("FovOpacity", {
        Text = "FOV opacity",
        Default = math.floor((Config.FOV_CIRCLE_TRANSPARENCY or 0.5) * 100),
        Min = 5,
        Max = 100,
        Rounding = 0,
        Compact = false,
        Suffix = "%",
        Callback = function(Value)
            updateSetting("FOV_CIRCLE_TRANSPARENCY", Value / 100)
        end
    })

    VisualSettings:AddToggle("AntiFlash", {
        Text = "Anti-flash",
        Default = (Config.ANTI_FLASH_ENABLED ~= false),
        Tooltip = "Neutralizes blinding white screen flashes and blindness effects",
        Callback = function(Value)
            updateSetting("ANTI_FLASH_ENABLED", Value)
        end
    })

    VisualSettings:AddSlider("FlashOpacity", {
        Text = "Flash opacity",
        Default = math.floor((Config.ANTI_FLASH_TRANSPARENCY or 0.85) * 100),
        Min = 5,
        Max = 100,
        Rounding = 0,
        Compact = false,
        Suffix = "%",
        Callback = function(Value)
            updateSetting("ANTI_FLASH_TRANSPARENCY", Value / 100)
        end
    })

    -- movement tab
    local MoveMain = Tabs.Movement:AddLeftGroupbox("Movement Physics")

    MoveMain:AddToggle("Bhop", {
        Text = "Bunny hop",
        Default = (Config.BHOP_ENABLED ~= false),
        Tooltip = "Automatic jump execution via native MovementV2 physics",
        Callback = function(Value)
            updateSetting("BHOP_ENABLED", Value)
        end
    })

    -- skins tab
    local SkinsBox = Tabs.Skins:AddLeftGroupbox("Skin Changer")
    SkinsBox:AddToggle("AutoLaunchSkinchanger", {
        Text = "Auto-launch on startup",
        Default = (Config.AUTO_LAUNCH_SKINCHANGER == true),
        Tooltip = "Automatically executes the standalone Skinchanger from GitHub when Bloxstrike is initialized",
        Callback = function(Value)
            updateSetting("AUTO_LAUNCH_SKINCHANGER", Value)
        end
    })

    SkinsBox:AddButton({
        Text = "Launch Skinchanger UI",
        Func = function()
            task.spawn(function()
                -- 1. Try local workspace files first
                if type(readfile) == "function" then
                    local localPaths = {
                        "roblox_bloxstrike_SC/init.lua",
                        "Bloxstrike-Skinchanger/init.lua"
                    }
                    for _, path in ipairs(localPaths) do
                        local okRead, content = pcall(readfile, path)
                        if okRead and content and #content > 0 then
                            local fn, loadErr = loadstring(content)
                            if fn then
                                local okExec, execErr = pcall(fn)
                                if okExec then
                                    Library:Notify("Skinchanger loaded (local)!", 2)
                                    return
                                else
                                    warn("[Bloxstrike] Local skinchanger execution error:", execErr)
                                end
                            end
                        end
                    end
                end

                -- 2. Remote GitHub with cache-busting timestamp
                Library:Notify("Fetching Skinchanger from GitHub...", 2)
                local okHttp, content = pcall(function()
                    return game:HttpGet("https://raw.githubusercontent.com/alvin12127/roblox_bloxstrike_SC/main/init.lua?t=" .. tostring(os.time()))
                end)
                if okHttp and content and #content > 0 then
                    local fn, loadErr = loadstring(content)
                    if fn then
                        local okExec, execErr = pcall(fn)
                        if okExec then
                            Library:Notify("Skinchanger loaded successfully!", 2)
                            return
                        else
                            warn("[Bloxstrike] Skinchanger execution error:", execErr)
                            Library:Notify("Execution error: " .. tostring(execErr), 4)
                            return
                        end
                    end
                end

                Library:Notify("Failed to fetch skinchanger from GitHub", 4)
            end)
        end,
        DoubleClick = false,
        Tooltip = "Executes the standalone Skinchanger (local/GitHub)"
    })




    -- settings tab
    local MenuGroup = Tabs.Settings:AddLeftGroupbox("Keybinds")
    local ActionsGroup = Tabs.Settings:AddRightGroupbox("Actions")

    local defaultMenuKey = (Config.TOGGLE_UI_KEY and Config.TOGGLE_UI_KEY.Name) or "Insert"
    MenuGroup:AddLabel("Menu toggle"):AddKeyPicker("MenuKeybind", {
        Default = defaultMenuKey,
        NoUI = true,
        Text = "Menu Key",
        ChangedCallback = function(NewKey)
            local key = (NewKey ~= "None") and Enum.KeyCode[NewKey] or nil
            updateSetting("TOGGLE_UI_KEY", key)
        end
    })

    local defaultAimKey = (type(Config.TOGGLE_AIM_KEY) == "string" and Config.TOGGLE_AIM_KEY) or (Config.TOGGLE_AIM_KEY and Config.TOGGLE_AIM_KEY.Name) or "None"
    MenuGroup:AddLabel("Silent aim bind"):AddKeyPicker("AimKeybind", {
        Default = defaultAimKey,
        Mode = Config.AIM_BIND_MODE or "Hold",
        NoUI = true,
        Text = "Silent aim bind",
        ChangedCallback = function(NewKey)
            local key = nil
            if NewKey and NewKey ~= "None" then
                if NewKey == "MB1" or NewKey == "MB2" or NewKey == "MB3" then
                    key = NewKey
                else
                    key = Enum.KeyCode[NewKey] or NewKey
                end
            end
            updateSetting("TOGGLE_AIM_KEY", key)
        end
    })

    MenuGroup:AddDropdown("AimBindMode", {
        Values = { "Toggle", "Hold" },
        Default = Config.AIM_BIND_MODE or "Toggle",
        Multi = false,
        Text = "Aim bind mode",
        Tooltip = "Toggle: Press key to toggle silent aim on/off\nHold: Hold key to activate silent aim",
        Callback = function(Value)
            updateSetting("AIM_BIND_MODE", Value)
            if Options and Options.AimKeybind then
                Options.AimKeybind.Mode = Value
                Options.AimKeybind.Toggled = false
            end
        end
    })

    local defaultEspKey = (Config.TOGGLE_ESP_KEY and Config.TOGGLE_ESP_KEY.Name) or "None"
    MenuGroup:AddLabel("Master ESP bind"):AddKeyPicker("EspKeybind", {
        Default = defaultEspKey,
        NoUI = true,
        Text = "Master ESP bind",
        ChangedCallback = function(NewKey)
            local key = (NewKey ~= "None") and Enum.KeyCode[NewKey] or nil
            updateSetting("TOGGLE_ESP_KEY", key)
        end
    })

    local defaultUnloadKey = (Config.UNLOAD_KEY and Config.UNLOAD_KEY.Name) or "K"
    MenuGroup:AddLabel("Unload / Kill script"):AddKeyPicker("UnloadKeybind", {
        Default = defaultUnloadKey,
        NoUI = true,
        Text = "Kill script",
        ChangedCallback = function(NewKey)
            local key = (NewKey ~= "None") and Enum.KeyCode[NewKey] or nil
            updateSetting("UNLOAD_KEY", key)
        end
    })

    Library.ToggleKeybind = Options.MenuKeybind

    ActionsGroup:AddButton({
        Text = "Reset defaults",
        Func = function()
            Config.reset()

            if Toggles.SilentAim then Toggles.SilentAim:SetValue(Config.SILENT_AIM_ENABLED) end
            if Toggles.KeepLock then Toggles.KeepLock:SetValue(Config.KEEP_TARGET_LOCK) end
            if Toggles.AimOcclusionCheck then Toggles.AimOcclusionCheck:SetValue(Config.AIM_OCCLUSION_CHECK) end
            if Options.TargetPriority then Options.TargetPriority:SetValue(Config.TARGET_PRIORITY or "Auto") end

            if Toggles.CustomRpm then Toggles.CustomRpm:SetValue(Config.CUSTOM_RPM_ENABLED) end
            if Options.RpmSlider then Options.RpmSlider:SetValue(Config.CUSTOM_RPM_VALUE or 1491) end
            if Toggles.ForceFullAuto then Toggles.ForceFullAuto:SetValue(Config.FORCE_FULL_AUTO) end
            if Toggles.Wallbang then Toggles.Wallbang:SetValue(Config.WALLBANG_ENABLED) end

            if Toggles.EspMaster then Toggles.EspMaster:SetValue(Config.ESP_ENABLED) end
            if Toggles.SkeletonEsp then Toggles.SkeletonEsp:SetValue(Config.SKELETON_ENABLED) end
            if Toggles.ViewAngle then Toggles.ViewAngle:SetValue(Config.VIEWANGLE_ENABLED) end
            if Toggles.OffscreenArrows then Toggles.OffscreenArrows:SetValue(Config.OFFSCREEN_ARROWS) end
            if Toggles.TargetPartHl then Toggles.TargetPartHl:SetValue(Config.BODYPART_TARGET_HL) end
            if Toggles.DisableTeammates then Toggles.DisableTeammates:SetValue(Config.DISABLE_TEAMMATES) end
            if Toggles.OcclusionCheck then Toggles.OcclusionCheck:SetValue(Config.OCCLUSION_CHECK_ENABLED) end
            if Toggles.SpectateChecker then Toggles.SpectateChecker:SetValue(Config.SPECTATE_CHECKER_ENABLED) end

            if Toggles.ShowFov then Toggles.ShowFov:SetValue(Config.FOV_CIRCLE_ENABLED) end
            if Options.FovAngle then Options.FovAngle:SetValue(Config.FOV_DEG or 30) end
            if Options.FovOpacity then Options.FovOpacity:SetValue(math.floor((Config.FOV_CIRCLE_TRANSPARENCY or 0.5) * 100)) end
            if Toggles.AntiFlash then Toggles.AntiFlash:SetValue(Config.ANTI_FLASH_ENABLED) end
            if Options.FlashOpacity then Options.FlashOpacity:SetValue(math.floor((Config.ANTI_FLASH_TRANSPARENCY or 0.85) * 100)) end

            if Toggles.Bhop then Toggles.Bhop:SetValue(Config.BHOP_ENABLED) end
            if Toggles.KnifeChanger then Toggles.KnifeChanger:SetValue(Config.KNIFE_SKINS_ENABLED ~= false) end
            if Toggles.WeaponChanger then Toggles.WeaponChanger:SetValue(Config.WEAPON_SKINS_ENABLED ~= false) end
            if Options.KnifeModel then Options.KnifeModel:SetValue(Config.KNIFE_MODEL or "Butterfly Knife") end
            if Options.KnifeSkin then Options.KnifeSkin:SetValue(Config.KNIFE_SKIN or "Special") end
            if Options.WeaponType then Options.WeaponType:SetValue("AK-47") end
            if Options.WeaponSkin then Options.WeaponSkin:SetValue("Special") end
            if Options.SkinMode then Options.SkinMode:SetValue(Config.SKIN_MODE or "Special") end

            if Options.MenuKeybind then Options.MenuKeybind:SetValue("Insert") end
            if Options.AimKeybind then Options.AimKeybind:SetValue("None") end
            if Options.AimBindMode then Options.AimBindMode:SetValue("Toggle") end
            if Options.EspKeybind then Options.EspKeybind:SetValue("None") end
            if Options.UnloadKeybind then Options.UnloadKeybind:SetValue("K") end

            Config.WINDOW_SIZE_X = 440
            Config.WINDOW_SIZE_Y = 210
            if Window and Window.Outer then
                Window.Outer.Size = UDim2.fromOffset(440, 210)
            end

            queueAutoSave()
            Library:Notify("Settings reset to defaults", 2)
        end,
        DoubleClick = false,
        Tooltip = "Resets all features and sliders to factory defaults"
    })

    ActionsGroup:AddButton({
        Text = "Unload suite",
        Func = function()
            if type(unloadCallback) == "function" then
                unloadCallback()
            elseif _G.__bloxstrikeJanitor then
                _G.__bloxstrikeJanitor()
            end
        end,
        DoubleClick = true,
        Tooltip = "Double click to completely unload the suite"
    })

    -- key listeners
    local function matchesAimKey(input)
        local key = Config.TOGGLE_AIM_KEY
        if not key or key == "None" then return false end

        if typeof(key) == "EnumItem" and key.EnumType == Enum.KeyCode then
            return input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == key
        end

        if type(key) == "string" then
            if key == "MB1" then
                return input.UserInputType == Enum.UserInputType.MouseButton1
            elseif key == "MB2" then
                return input.UserInputType == Enum.UserInputType.MouseButton2
            elseif key == "MB3" then
                return input.UserInputType == Enum.UserInputType.MouseButton3
            elseif Enum.KeyCode[key] then
                return input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode[key]
            end
        end

        return false
    end

    local bindInputBegan = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if Library and Library.IsPickingKey then return end
        if UserInputService:GetFocusedTextBox() then return end

        if matchesAimKey(input) then
            if Config.AIM_BIND_MODE == "Toggle" then
                local nextState = not Config.SILENT_AIM_ENABLED
                updateSetting("SILENT_AIM_ENABLED", nextState)
                if Toggles.SilentAim and Toggles.SilentAim.Value ~= nextState then
                    Toggles.SilentAim:SetValue(nextState)
                end
            end
        elseif Config.TOGGLE_ESP_KEY and input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Config.TOGGLE_ESP_KEY then
            local nextState = not Config.ESP_ENABLED
            updateSetting("ESP_ENABLED", nextState)
            if Toggles.EspMaster and Toggles.EspMaster.Value ~= nextState then
                Toggles.EspMaster:SetValue(nextState)
            end
        end
    end)
    table.insert(UIManager.Connections, bindInputBegan)

    -- block in-game weapon switching while menu is open
    pcall(function()
        local InventoryController = require(ReplicatedStorage.Controllers.InventoryController)
        if InventoryController then
            if not _G.__originalInventoryEquip then
                _G.__originalInventoryEquip = InventoryController.equip
            end
            local origEquip = _G.__originalInventoryEquip

            if not _G.__originalInventoryEquipLocal then
                _G.__originalInventoryEquipLocal = InventoryController.equipLocal
            end
            local origEquipLocal = _G.__originalInventoryEquipLocal

            InventoryController.equip = function(slot, index, ...)
                if Library and Library.Toggled then
                    return
                end
                return origEquip(slot, index, ...)
            end

            if origEquipLocal then
                InventoryController.equipLocal = function(slot, index, ...)
                    if Library and Library.Toggled then
                        return
                    end
                    return origEquipLocal(slot, index, ...)
                end
            end
        end
    end)

    Library:Notify("@Discord_alvin6974. / Bloxstrike / v2.5 Loaded!", 3)
end

function UIManager.cleanup()
    for _, c in ipairs(UIManager.Connections) do
        pcall(function() c:Disconnect() end)
    end
    UIManager.Connections = {}

    pcall(function()
        local InventoryController = require(ReplicatedStorage.Controllers.InventoryController)
        if InventoryController then
            if _G.__originalInventoryEquip then
                InventoryController.equip = _G.__originalInventoryEquip
                _G.__originalInventoryEquip = nil
            end
            if _G.__originalInventoryEquipLocal then
                InventoryController.equipLocal = _G.__originalInventoryEquipLocal
                _G.__originalInventoryEquipLocal = nil
            end
        end
    end)

    local Library = UIManager.Library
    if Library and Library.Unload then
        pcall(function() Library:Unload() end)
    end

    UIManager.Library = nil
    UIManager.Window = nil
    UIManager.Initialized = false
end

return UIManager
