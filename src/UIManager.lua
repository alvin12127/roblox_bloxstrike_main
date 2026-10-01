-- ui manager (arvn-based)
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

function UIManager.init(Config, Arvn, SkinChanger, WeaponEngine, unloadCallback, HitSound)
    if UIManager.Initialized then return end
    UIManager.Initialized = true
    UIManager.Library = Arvn
    
    -- Validate Arvn
    if not Arvn or type(Arvn.CreateWindow) ~= "function" then
        warn("[Bloxstrike] Arvn library not loaded properly")
        UIManager.Initialized = false
        UIManager.Library = nil
        return
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
    local Window = Arvn:CreateWindow({
        Title = "@Discord_alvin6974. / Bloxstrike / v2.5",
        Author = "@Discord_alvin6974.",
        Folder = "Bloxstrike"
    })
    UIManager.Window = Window

    local Main = Window:Group("Main")

    -- aim tab
    local AimTab = Main:Tab({Name = "Aim", Icon = "crosshair"})
    local AimSection = AimTab:Section("Silent Aim")

    AimSection:Toggle({
        Name = "Silent aim",
        Default = (Config.SILENT_AIM_ENABLED ~= false),
        Description = "Redirects bullets directly to optimal enemy hitbox within FOV cone",
        Callback = function(on)
            updateSetting("SILENT_AIM_ENABLED", on)
        end
    })

    AimSection:Toggle({
        Name = "Keep target lock",
        Default = (Config.KEEP_TARGET_LOCK ~= false),
        Description = "Maintains lock on current target while firing",
        Callback = function(on)
            updateSetting("KEEP_TARGET_LOCK", on)
        end
    })

    AimSection:Toggle({
        Name = "Occlusion check",
        Default = (Config.AIM_OCCLUSION_CHECK == true),
        Description = "Prevents bullet redirection if all hitboxes of a target are occluded behind walls",
        Callback = function(on)
            updateSetting("AIM_OCCLUSION_CHECK", on)
        end
    })

    AimSection:Dropdown({
        Name = "Target priority",
        Values = {"Auto", "Head", "Torso", "Random"},
        Default = Config.TARGET_PRIORITY or "Auto",
        Description = "Auto: Lethal damage calculation and occlusion scanner\nHead: Strictly headshots\nTorso: Upper and lower torso\nRandom: Random visible hitbox",
        Callback = function(value)
            updateSetting("TARGET_PRIORITY", value)
        end
    })

    local AimAccuracy = AimTab:Section({Name = "Accuracy & FOV", Side = "Right"})

    AimAccuracy:Toggle({
        Name = "Hit chance",
        Default = (Config.HIT_CHANCE_ENABLED == true),
        Description = "Adds a miss chance per bullet. Failed rolls are not redirected and travel with the weapon's natural spread.",
        Callback = function(on)
            updateSetting("HIT_CHANCE_ENABLED", on)
        end
    })

    AimAccuracy:Slider({
        Name = "Chance",
        Min = 0,
        Max = 100,
        Default = Config.HIT_CHANCE or 100,
        Suffix = "%",
        Description = "100 = every shot is redirected, 0 = silent aim never redirects",
        Callback = function(value)
            updateSetting("HIT_CHANCE", value)
        end
    })

    AimAccuracy:Slider({
        Name = "FOV angle",
        Min = 1,
        Max = 180,
        Default = Config.FOV_DEG or 30,
        Suffix = "°",
        Description = "Maximum angle from the crosshair. Used for target scanning and for the FOV circle.",
        Callback = function(value)
            updateSetting("FOV_DEG", value)
        end
    })

    -- weapons tab
    local WeaponsTab = Main:Tab({Name = "Weapons", Icon = "sword"})
    local WeaponFire = WeaponsTab:Section("Fire Rate & Trigger")

    WeaponFire:Toggle({
        Name = "Custom fire rate (RPM)",
        Default = (Config.CUSTOM_RPM_ENABLED == true),
        Description = "Overrides the fire rate for all equipped and database weapons",
        Callback = function(on)
            updateSetting("CUSTOM_RPM_ENABLED", on)
            if WeaponEngine and WeaponEngine.sync then WeaponEngine.sync(Config) end
        end
    })

    WeaponFire:Slider({
        Name = "Fire rate (RPM)",
        Min = 60,
        Max = 3000,
        Default = Config.CUSTOM_RPM_VALUE or 600,
        Suffix = " RPM",
        Description = "Rounds per minute. Standard rifles: ~600-800 RPM. Rapid fire: 1500-3000 RPM.",
        Callback = function(value)
            updateSetting("CUSTOM_RPM_VALUE", value)
            if WeaponEngine and WeaponEngine.sync then WeaponEngine.sync(Config) end
        end
    })

    WeaponFire:Toggle({
        Name = "Force full auto",
        Default = (Config.FORCE_FULL_AUTO == true),
        Description = "Converts all semi-automatic pistols, shotguns, and snipers to full-automatic",
        Callback = function(on)
            updateSetting("FORCE_FULL_AUTO", on)
            if WeaponEngine and WeaponEngine.sync then WeaponEngine.sync(Config) end
        end
    })

    WeaponFire:Toggle({
        Name = "Instant reload",
        Default = (Config.INSTANT_RELOAD == true),
        Description = "Makes reload animations finish instantly",
        Callback = function(on)
            updateSetting("INSTANT_RELOAD", on)
        end
    })

    local WeaponPen = WeaponsTab:Section({Name = "Penetration & Wallbang", Side = "Right"})

    WeaponPen:Toggle({
        Name = "Infinite wallbang",
        Default = (Config.WALLBANG_ENABLED == true),
        Description = "Fabricates bullet hits through any wall. Requires silent aim to lock a target.",
        Callback = function(on)
            updateSetting("WALLBANG_ENABLED", on)
        end
    })

    WeaponPen:Toggle({
        Name = "No recoil",
        Default = (Config.NO_RECOIL == true),
        Description = "Zeroes every recoil field in the weapon database. Original values are restored on unload.",
        Callback = function(on)
            updateSetting("NO_RECOIL", on)
            if WeaponEngine and WeaponEngine.sync then WeaponEngine.sync(Config) end
        end
    })

    WeaponPen:Toggle({
        Name = "No spread",
        Default = (Config.NO_SPREAD == true),
        Description = "Removes bullet deviation, both in the weapon database and per shot.",
        Callback = function(on)
            updateSetting("NO_SPREAD", on)
            if WeaponEngine and WeaponEngine.sync then WeaponEngine.sync(Config) end
        end
    })

    -- visuals tab
    local VisualsTab = Main:Tab({Name = "Visuals", Icon = "eye"})
    local EspMain = VisualsTab:Section("ESP Elements")

    EspMain:Toggle({
        Name = "Enable ESP",
        Default = (Config.ESP_ENABLED ~= false),
        Description = "Master switch to enable or disable all visual ESP features",
        Callback = function(on)
            updateSetting("ESP_ENABLED", on)
        end
    })

    EspMain:Toggle({
        Name = "Skeleton ESP",
        Default = (Config.SKELETON_ENABLED ~= false),
        Description = "Renders 3D bone skeletons and health bars on characters",
        Callback = function(on)
            updateSetting("SKELETON_ENABLED", on)
        end
    })

    EspMain:Toggle({
        Name = "Name ESP",
        Default = (Config.NAME_ESP_ENABLED ~= false),
        Description = "Player name rendered above the skeleton",
        Callback = function(on)
            updateSetting("NAME_ESP_ENABLED", on)
        end
    })

    EspMain:Toggle({
        Name = "Equipped item ESP",
        Default = (Config.ITEM_ESP_ENABLED ~= false),
        Description = "Currently held weapon rendered below the skeleton",
        Callback = function(on)
            updateSetting("ITEM_ESP_ENABLED", on)
        end
    })

    EspMain:Toggle({
        Name = "View angle",
        Default = (Config.VIEWANGLE_ENABLED ~= false),
        Description = "Renders head look direction indicator ray",
        Callback = function(on)
            updateSetting("VIEWANGLE_ENABLED", on)
        end
    })

    EspMain:Toggle({
        Name = "Offscreen arrows",
        Default = (Config.OFFSCREEN_ARROWS ~= false),
        Description = "Directional triangle pointers for out-of-view enemies with distance fade",
        Callback = function(on)
            updateSetting("OFFSCREEN_ARROWS", on)
        end
    })

    EspMain:Toggle({
        Name = "Visualize target part",
        Default = (Config.BODYPART_TARGET_HL ~= false),
        Description = "Highlights active targeted limb with yellow outline",
        Callback = function(on)
            updateSetting("BODYPART_TARGET_HL", on)
        end
    })

    EspMain:Toggle({
        Name = "Disable teammates",
        Default = (Config.DISABLE_TEAMMATES == true),
        Description = "Hides ESP and offscreen arrows for friendly teammates",
        Callback = function(on)
            updateSetting("DISABLE_TEAMMATES", on)
        end
    })

    EspMain:Toggle({
        Name = "Occlusion check",
        Default = (Config.OCCLUSION_CHECK_ENABLED ~= false),
        Description = "Dims skeleton bone color when character is behind walls",
        Callback = function(on)
            updateSetting("OCCLUSION_CHECK_ENABLED", on)
        end
    })

    EspMain:Toggle({
        Name = "Spectator counter",
        Default = (Config.SPECTATE_CHECKER_ENABLED ~= false),
        Description = "HUD widget displaying players spectating your camera",
        Callback = function(on)
            updateSetting("SPECTATE_CHECKER_ENABLED", on)
        end
    })

    local VisualSettings = VisualsTab:Section({Name = "FOV & Utilities", Side = "Right"})

    VisualSettings:Toggle({
        Name = "Show FOV circle",
        Default = (Config.FOV_CIRCLE_ENABLED ~= false),
        Description = "Renders screen-center FOV boundary",
        Callback = function(on)
            updateSetting("FOV_CIRCLE_ENABLED", on)
        end
    })

    VisualSettings:Slider({
        Name = "FOV opacity",
        Min = 5,
        Max = 100,
        Default = math.floor((Config.FOV_CIRCLE_TRANSPARENCY or 0.5) * 100),
        Suffix = "%",
        Callback = function(value)
            updateSetting("FOV_CIRCLE_TRANSPARENCY", value / 100)
        end
    })

    VisualSettings:Toggle({
        Name = "Box ESP",
        Default = (Config.BOX_ESP_ENABLED ~= false),
        Description = "Bounding cube rendered around every enemy",
        Callback = function(on)
            updateSetting("BOX_ESP_ENABLED", on)
        end
    })

    VisualSettings:Toggle({
        Name = "Corner only",
        Default = (Config.BOX_ESP_CORNERS_ONLY ~= false),
        Description = "Renders only the four corners of the box instead of the full outline",
        Callback = function(on)
            updateSetting("BOX_ESP_CORNERS_ONLY", on)
        end
    })

    VisualSettings:Toggle({
        Name = "C4 ESP",
        Default = (Config.C4_ESP_ENABLED == true),
        Description = "Marks the player carrying the bomb, and the bomb itself on the ground or planted",
        Callback = function(on)
            updateSetting("C4_ESP_ENABLED", on)
        end
    })

    VisualSettings:Toggle({
        Name = "Anti-flash",
        Default = (Config.ANTI_FLASH_ENABLED ~= false),
        Description = "Neutralizes blinding white screen flashes and blindness effects",
        Callback = function(on)
            updateSetting("ANTI_FLASH_ENABLED", on)
        end
    })

    VisualSettings:Slider({
        Name = "Flash opacity",
        Min = 5,
        Max = 100,
        Default = math.floor((Config.ANTI_FLASH_TRANSPARENCY or 0.85) * 100),
        Suffix = "%",
        Callback = function(value)
            updateSetting("ANTI_FLASH_TRANSPARENCY", value / 100)
        end
    })

    -- bullet tracer panel
    local TracerBox = VisualsTab:Section({Name = "Bullet Tracer", Side = "Right"})

    TracerBox:Toggle({
        Name = "Enable tracers",
        Default = (Config.BULLET_TRACER_ENABLED == true),
        Description = "Draws the flight path of every bullet you fire",
        Callback = function(on)
            updateSetting("BULLET_TRACER_ENABLED", on)
        end
    })

    TracerBox:ColorPicker({
        Name = "Tracer color",
        Default = Config.BULLET_TRACER_COLOR or Color3.fromRGB(186, 140, 255),
        Callback = function(value)
            updateSetting("BULLET_TRACER_COLOR", value)
        end
    })

    TracerBox:Slider({
        Name = "Line thickness",
        Min = 0.1,
        Max = 6,
        Default = Config.BULLET_TRACER_THICKNESS or 1.5,
        Suffix = " px",
        Callback = function(value)
            updateSetting("BULLET_TRACER_THICKNESS", value)
        end
    })

    TracerBox:Slider({
        Name = "Fade time",
        Min = 1,
        Max = 30,
        Default = (Config.BULLET_TRACER_DURATION or 0.6) * 10,
        Suffix = " (x0.1s)",
        Description = "How long the tracer stays on screen before it fades out",
        Callback = function(value)
            updateSetting("BULLET_TRACER_DURATION", value / 10)
        end
    })

    -- chams panel
    local ChamsBox = VisualsTab:Section({Name = "Chams", Side = "Right"})

    ChamsBox:Toggle({
        Name = "Enable chams",
        Default = (Config.CHAMS_ENABLED == true),
        Description = "Colors enemy characters through walls",
        Callback = function(on)
            updateSetting("CHAMS_ENABLED", on)
        end
    })

    ChamsBox:Toggle({
        Name = "Through walls",
        Default = (Config.CHAMS_THROUGH_WALLS ~= false),
        Description = "Render chams through walls",
        Callback = function(on)
            updateSetting("CHAMS_THROUGH_WALLS", on)
        end
    })

    ChamsBox:Dropdown({
        Name = "Mode",
        Values = {"Fill", "Outline", "Both"},
        Default = Config.CHAMS_MODE or "Both",
        Description = "Fill: Only fill\nOutline: Only outline\nBoth: Fill and outline",
        Callback = function(value)
            updateSetting("CHAMS_MODE", value)
        end
    })

    ChamsBox:Dropdown({
        Name = "Style",
        Values = {"Solid", "Pulse", "Rainbow", "Gradient", "Wireframe", "Distance"},
        Default = Config.CHAMS_STYLE or "Solid",
        Description = "Solid: Static color\nPulse: Pulsing transparency\nRainbow: Cycling hue\nGradient: Color blend\nWireframe: Outline only\nDistance: Distance-based color",
        Callback = function(value)
            updateSetting("CHAMS_STYLE", value)
        end
    })

    ChamsBox:ColorPicker({
        Name = "Primary color",
        Default = Config.CHAMS_COLOR or Color3.fromRGB(255, 60, 60),
        Callback = function(value)
            updateSetting("CHAMS_COLOR", value)
        end
    })

    ChamsBox:ColorPicker({
        Name = "Secondary color",
        Default = Config.CHAMS_COLOR_SECONDARY or Color3.fromRGB(60, 200, 255),
        Callback = function(value)
            updateSetting("CHAMS_COLOR_SECONDARY", value)
        end
    })

    ChamsBox:Slider({
        Name = "Fill transparency",
        Min = 0,
        Max = 1,
        Default = Config.CHAMS_FILL_TRANSPARENCY or 0.5,
        Callback = function(value)
            updateSetting("CHAMS_FILL_TRANSPARENCY", value)
        end
    })

    ChamsBox:Slider({
        Name = "Outline transparency",
        Min = 0,
        Max = 1,
        Default = Config.CHAMS_OUTLINE_TRANSPARENCY or 0.8,
        Callback = function(value)
            updateSetting("CHAMS_OUTLINE_TRANSPARENCY", value)
        end
    })

    ChamsBox:Slider({
        Name = "Pulse speed",
        Min = 0.5,
        Max = 10,
        Default = Config.CHAMS_PULSE_SPEED or 3,
        Suffix = "x",
        Callback = function(value)
            updateSetting("CHAMS_PULSE_SPEED", value)
        end
    })

    ChamsBox:Slider({
        Name = "Gradient speed",
        Min = 0.5,
        Max = 10,
        Default = Config.CHAMS_GRADIENT_SPEED or 2,
        Suffix = "x",
        Callback = function(value)
            updateSetting("CHAMS_GRADIENT_SPEED", value)
        end
    })

    ChamsBox:Slider({
        Name = "Distance near",
        Min = 10,
        Max = 500,
        Default = Config.CHAMS_DISTANCE_NEAR or 100,
        Suffix = " s",
        Callback = function(value)
            updateSetting("CHAMS_DISTANCE_NEAR", value)
        end
    })

    ChamsBox:Slider({
        Name = "Distance far",
        Min = 100,
        Max = 3000,
        Default = Config.CHAMS_DISTANCE_FAR or 1500,
        Suffix = " s",
        Callback = function(value)
            updateSetting("CHAMS_DISTANCE_FAR", value)
        end
    })

    -- movement tab
    local MovementTab = Main:Tab({Name = "Movement", Icon = "move"})
    local MoveMain = MovementTab:Section("Movement Physics")

    MoveMain:Toggle({
        Name = "Bunny hop",
        Default = (Config.BHOP_ENABLED ~= false),
        Description = "Automatic jump execution via native MovementV2 physics",
        Callback = function(on)
            updateSetting("BHOP_ENABLED", on)
        end
    })

    MoveMain:Toggle({
        Name = "Auto jump",
        Default = (Config.BHOP_AUTO_JUMP ~= false),
        Description = "Automatically jumps when grounded",
        Callback = function(on)
            updateSetting("BHOP_AUTO_JUMP", on)
        end
    })

    MoveMain:Toggle({
        Name = "Auto strafe",
        Default = (Config.BHOP_AUTO_STRAFE ~= false),
        Description = "Automatically strafes in the air",
        Callback = function(on)
            updateSetting("BHOP_AUTO_STRAFE", on)
        end
    })

    MoveMain:Slider({
        Name = "Strafe force",
        Min = 0.5,
        Max = 10,
        Default = Config.BHOP_STRAFE_FORCE or 2,
        Suffix = "x",
        Callback = function(value)
            updateSetting("BHOP_STRAFE_FORCE", value)
        end
    })

    MoveMain:Slider({
        Name = "Min speed",
        Min = 0,
        Max = 50,
        Default = Config.BHOP_MIN_SPEED or 10,
        Suffix = " s/s",
        Callback = function(value)
            updateSetting("BHOP_MIN_SPEED", value)
        end
    })

    MoveMain:Dropdown({
        Name = "Mode",
        Values = {"Legit", "Rage"},
        Default = Config.BHOP_MODE or "Legit",
        Description = "Legit: Wait for space input\nRage: Auto hop without input",
        Callback = function(value)
            updateSetting("BHOP_MODE", value)
        end
    })

    MoveMain:Toggle({
        Name = "Teleport boost",
        Default = (Config.BHOP_TELEPORT_BOOST == true),
        Description = "Boosts movement on jump",
        Callback = function(on)
            updateSetting("BHOP_TELEPORT_BOOST", on)
        end
    })

    MoveMain:Slider({
        Name = "Teleport distance",
        Min = 0.05,
        Max = 1,
        Default = Config.BHOP_TELEPORT_DISTANCE or 0.5,
        Suffix = " studs",
        Callback = function(value)
            updateSetting("BHOP_TELEPORT_DISTANCE", value)
        end
    })

    -- spin bot, anti aim
    local AimControl = MovementTab:Section({Name = "Spin Bot & Anti Aim", Side = "Right"})

    AimControl:Toggle({
        Name = "Spin bot",
        Default = (Config.SPINBOT_ENABLED == true),
        Description = "Spins the local rig continuously. Only affects what is shown on screen.",
        Callback = function(on)
            updateSetting("SPINBOT_ENABLED", on)
        end
    })

    AimControl:Slider({
        Name = "Spin speed",
        Min = 60,
        Max = 3000,
        Default = Config.SPINBOT_RPM or 600,
        Suffix = " RPM",
        Callback = function(value)
            updateSetting("SPINBOT_RPM", value)
        end
    })

    AimControl:Toggle({
        Name = "Anti aim",
        Default = (Config.ANTIAIM_ENABLED == true),
        Description = "Tilts the local rig so the head is harder to read",
        Callback = function(on)
            updateSetting("ANTIAIM_ENABLED", on)
        end
    })

    AimControl:Dropdown({
        Name = "Yaw base",
        Values = {"Off", "Spin", "Jitter", "Random"},
        Default = Config.ANTIAIM_YAW_BASE or "Off",
        Description = "Off: No yaw modification\nSpin: Continuous rotation\nJitter: Random jitter\nRandom: Random yaw",
        Callback = function(value)
            updateSetting("ANTIAIM_YAW_BASE", value)
        end
    })

    AimControl:Slider({
        Name = "Yaw offset",
        Min = -180,
        Max = 180,
        Default = Config.ANTIAIM_YAW_OFFSET or 0,
        Suffix = "°",
        Callback = function(value)
            updateSetting("ANTIAIM_YAW_OFFSET", value)
        end
    })

    AimControl:Slider({
        Name = "Spin speed",
        Min = 30,
        Max = 720,
        Default = Config.ANTIAIM_SPIN_SPEED or 360,
        Suffix = "°/s",
        Callback = function(value)
            updateSetting("ANTIAIM_SPIN_SPEED", value)
        end
    })

    AimControl:Slider({
        Name = "Jitter offset",
        Min = 5,
        Max = 90,
        Default = Config.ANTIAIM_JITTER_OFFSET or 30,
        Suffix = "°",
        Callback = function(value)
            updateSetting("ANTIAIM_JITTER_OFFSET", value)
        end
    })

    AimControl:Slider({
        Name = "Pitch",
        Min = 0,
        Max = 120,
        Default = Config.ANTIAIM_PITCH or 60,
        Suffix = "°",
        Callback = function(value)
            updateSetting("ANTIAIM_PITCH", value)
        end
    })

    -- world tab
    local WorldTab = Main:Tab({Name = "World", Icon = "sun"})

    -- camera section
    local CameraBox = WorldTab:Section("Camera")

    CameraBox:Toggle({
        Name = "Custom camera FOV",
        Default = (Config.CAMERA_FOV_ENABLED == true),
        Description = "Overrides the camera field of view. The original value is restored when switched off.",
        Callback = function(on)
            updateSetting("CAMERA_FOV_ENABLED", on)
        end
    })

    CameraBox:Slider({
        Name = "FOV",
        Min = 30,
        Max = 120,
        Default = Config.CAMERA_FOV_VALUE or 90,
        Suffix = "°",
        Callback = function(value)
            updateSetting("CAMERA_FOV_VALUE", value)
        end
    })

    -- lighting section
    local LightingBox = WorldTab:Section({Name = "Lighting", Side = "Right"})

    LightingBox:Toggle({
        Name = "Custom clock time",
        Default = (Config.CLOCK_TIME_ENABLED == true),
        Description = "Sets the in-game time",
        Callback = function(on)
            updateSetting("CLOCK_TIME_ENABLED", on)
        end
    })

    LightingBox:Slider({
        Name = "Time",
        Min = 0,
        Max = 24,
        Default = Config.CLOCK_TIME or 14,
        Suffix = "h",
        Callback = function(value)
            updateSetting("CLOCK_TIME", value)
        end
    })

    LightingBox:Toggle({
        Name = "Custom brightness",
        Default = (Config.BRIGHTNESS_ENABLED == true),
        Description = "Overrides the game brightness",
        Callback = function(on)
            updateSetting("BRIGHTNESS_ENABLED", on)
        end
    })

    LightingBox:Slider({
        Name = "Brightness",
        Min = 0,
        Max = 10,
        Default = Config.BRIGHTNESS or 2,
        Callback = function(value)
            updateSetting("BRIGHTNESS", value)
        end
    })

    LightingBox:Toggle({
        Name = "Custom ambient",
        Default = (Config.AMBIENT_ENABLED == true),
        Description = "Overrides the ambient color",
        Callback = function(on)
            updateSetting("AMBIENT_ENABLED", on)
        end
    })

    LightingBox:ColorPicker({
        Name = "Ambient color",
        Default = Config.AMBIENT_COLOR or Color3.fromRGB(100, 100, 100),
        Callback = function(value)
            updateSetting("AMBIENT_COLOR", value)
        end
    })

    LightingBox:Toggle({
        Name = "Custom outdoor ambient",
        Default = (Config.OUTDOOR_AMBIENT_ENABLED == true),
        Description = "Overrides the outdoor ambient color",
        Callback = function(on)
            updateSetting("OUTDOOR_AMBIENT_ENABLED", on)
        end
    })

    LightingBox:ColorPicker({
        Name = "Outdoor ambient color",
        Default = Config.OUTDOOR_AMBIENT_COLOR or Color3.fromRGB(100, 100, 100),
        Callback = function(value)
            updateSetting("OUTDOOR_AMBIENT_COLOR", value)
        end
    })

    -- world modifiers section
    local WorldModsBox = WorldTab:Section({Name = "World Mods", Side = "Right"})

    WorldModsBox:Toggle({
        Name = "Fullbright",
        Default = (Config.FULLBRIGHT == true),
        Description = "Removes all shadows and makes everything bright",
        Callback = function(on)
            updateSetting("FULLBRIGHT", on)
        end
    })

    WorldModsBox:Toggle({
        Name = "No fog",
        Default = (Config.NO_FOG == true),
        Description = "Removes fog from the game",
        Callback = function(on)
            updateSetting("NO_FOG", on)
        end
    })

    WorldModsBox:Toggle({
        Name = "No textures",
        Default = (Config.NO_TEXTURES == true),
        Description = "Removes textures from map parts",
        Callback = function(on)
            updateSetting("NO_TEXTURES", on)
        end
    })

    WorldModsBox:Toggle({
        Name = "Remove grass",
        Default = (Config.REMOVE_GRASS == true),
        Description = "Removes grass decoration from terrain",
        Callback = function(on)
            updateSetting("REMOVE_GRASS", on)
        end
    })

    WorldModsBox:Toggle({
        Name = "Custom skybox",
        Default = (Config.SKYBOX_ENABLED == true),
        Description = "Replaces the game skybox",
        Callback = function(on)
            updateSetting("SKYBOX_ENABLED", on)
        end
    })

    WorldModsBox:Input({
        Name = "Skybox asset ID",
        Default = Config.SKYBOX_ID or "rbxassetid://159454299",
        Description = "Roblox asset ID for the skybox",
        Callback = function(value)
            updateSetting("SKYBOX_ID", value)
        end
    })

    -- map color section
    local MapColorBox = WorldTab:Section({Name = "Map Color", Side = "Right"})

    MapColorBox:Toggle({
        Name = "Enable map color",
        Default = (Config.MAP_COLOR_ENABLED == true),
        Description = "Tints the map with a custom color",
        Callback = function(on)
            updateSetting("MAP_COLOR_ENABLED", on)
        end
    })

    MapColorBox:Dropdown({
        Name = "Mode",
        Values = {"Tint", "Ambient", "Both", "Saturation"},
        Default = Config.MAP_COLOR_MODE or "Tint",
        Description = "Tint: Part colors\nAmbient: Lighting ambient\nBoth: Tint and ambient\nSaturation: Color correction saturation",
        Callback = function(value)
            updateSetting("MAP_COLOR_MODE", value)
        end
    })

    MapColorBox:ColorPicker({
        Name = "Map color",
        Default = Config.MAP_COLOR or Color3.fromRGB(255, 255, 255),
        Callback = function(value)
            updateSetting("MAP_COLOR", value)
        end
    })

    MapColorBox:Slider({
        Name = "Saturation",
        Min = -1,
        Max = 1,
        Default = Config.MAP_SATURATION or 0,
        Callback = function(value)
            updateSetting("MAP_SATURATION", value)
        end
    })

    -- post processing section
    local PostFxBox = WorldTab:Section({Name = "Post FX", Side = "Right"})

    PostFxBox:Toggle({
        Name = "Bloom",
        Default = (Config.BLOOM_ENABLED == true),
        Description = "Adds a bloom effect to bright areas",
        Callback = function(on)
            updateSetting("BLOOM_ENABLED", on)
        end
    })

    PostFxBox:Slider({
        Name = "Intensity",
        Min = 0,
        Max = 5,
        Default = Config.BLOOM_INTENSITY or 1,
        Callback = function(value)
            updateSetting("BLOOM_INTENSITY", value)
        end
    })

    PostFxBox:Slider({
        Name = "Size",
        Min = 0,
        Max = 100,
        Default = Config.BLOOM_SIZE or 24,
        Callback = function(value)
            updateSetting("BLOOM_SIZE", value)
        end
    })

    PostFxBox:Slider({
        Name = "Threshold",
        Min = 0,
        Max = 1,
        Default = Config.BLOOM_THRESHOLD or 0.9,
        Callback = function(value)
            updateSetting("BLOOM_THRESHOLD", value)
        end
    })

    PostFxBox:Toggle({
        Name = "Color correction",
        Default = (Config.COLOR_CORRECTION_ENABLED == true),
        Description = "Adjusts brightness, contrast, saturation and tint",
        Callback = function(on)
            updateSetting("COLOR_CORRECTION_ENABLED", on)
        end
    })

    PostFxBox:Slider({
        Name = "Brightness",
        Min = -1,
        Max = 1,
        Default = Config.CC_BRIGHTNESS or 0,
        Callback = function(value)
            updateSetting("CC_BRIGHTNESS", value)
        end
    })

    PostFxBox:Slider({
        Name = "Contrast",
        Min = -1,
        Max = 1,
        Default = Config.CC_CONTRAST or 0,
        Callback = function(value)
            updateSetting("CC_CONTRAST", value)
        end
    })

    PostFxBox:Slider({
        Name = "Saturation",
        Min = -1,
        Max = 1,
        Default = Config.CC_SATURATION or 0,
        Callback = function(value)
            updateSetting("CC_SATURATION", value)
        end
    })

    PostFxBox:ColorPicker({
        Name = "Tint color",
        Default = Config.CC_TINT_COLOR or Color3.fromRGB(255, 255, 255),
        Callback = function(value)
            updateSetting("CC_TINT_COLOR", value)
        end
    })

    PostFxBox:Toggle({
        Name = "Sun rays",
        Default = (Config.SUN_RAYS_ENABLED == true),
        Description = "Adds sun rays effect",
        Callback = function(on)
            updateSetting("SUN_RAYS_ENABLED", on)
        end
    })

    PostFxBox:Slider({
        Name = "Intensity",
        Min = 0,
        Max = 2,
        Default = Config.SUN_RAYS_INTENSITY or 0.25,
        Callback = function(value)
            updateSetting("SUN_RAYS_INTENSITY", value)
        end
    })

    PostFxBox:Slider({
        Name = "Spread",
        Min = 0,
        Max = 2,
        Default = Config.SUN_RAYS_SPREAD or 1,
        Callback = function(value)
            updateSetting("SUN_RAYS_SPREAD", value)
        end
    })

    PostFxBox:Toggle({
        Name = "Motion blur",
        Default = (Config.MOTION_BLUR_ENABLED == true),
        Description = "Adds motion blur effect",
        Callback = function(on)
            updateSetting("MOTION_BLUR_ENABLED", on)
        end
    })

    PostFxBox:Slider({
        Name = "Strength",
        Min = 0,
        Max = 10,
        Default = Config.MOTION_BLUR_STRENGTH or 1,
        Callback = function(value)
            updateSetting("MOTION_BLUR_STRENGTH", value)
        end
    })

    -- third person section
    local ThirdPersonBox = WorldTab:Section({Name = "Third Person", Side = "Right"})

    ThirdPersonBox:Toggle({
        Name = "Third person",
        Default = (Config.THIRDPERSON_ENABLED == true),
        Description = "Pulls the camera back behind the rig. Mouse look is unaffected.",
        Callback = function(on)
            updateSetting("THIRDPERSON_ENABLED", on)
        end
    })

    ThirdPersonBox:Slider({
        Name = "Distance",
        Min = 4,
        Max = 40,
        Default = Config.THIRDPERSON_DISTANCE or 9,
        Suffix = " studs",
        Callback = function(value)
            updateSetting("THIRDPERSON_DISTANCE", value)
        end
    })

    ThirdPersonBox:Slider({
        Name = "Height offset",
        Min = -6,
        Max = 10,
        Default = Config.THIRDPERSON_HEIGHT or 0,
        Suffix = " studs",
        Callback = function(value)
            updateSetting("THIRDPERSON_HEIGHT", value)
        end
    })

    ThirdPersonBox:Toggle({
        Name = "Camera lock guard",
        Default = (Config.THIRDPERSON_GUARD ~= false),
        Description = "Stops the game forcing first person back. Turn off if it ever interferes with another script.",
        Callback = function(on)
            updateSetting("THIRDPERSON_GUARD", on)
        end
    })

    -- skins tab
    local SkinsTab = Main:Tab({Name = "Skins", Icon = "palette"})
    local SkinsBox = SkinsTab:Section("Skin Changer")

    SkinsBox:Toggle({
        Name = "Auto-launch on startup",
        Default = (Config.AUTO_LAUNCH_SKINCHANGER == true),
        Description = "Automatically executes the standalone Skinchanger from GitHub when Bloxstrike is initialized",
        Callback = function(on)
            updateSetting("AUTO_LAUNCH_SKINCHANGER", on)
        end
    })

    SkinsBox:Button({
        Name = "Launch Skinchanger UI",
        Callback = function()
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
                                    Arvn:Notify({Title = "Skinchanger", Content = "Loaded locally!", Kind = "Success"})
                                    return
                                else
                                    warn("[Bloxstrike] Local skinchanger execution error:", execErr)
                                end
                            end
                        end
                    end
                end

                -- 2. Remote GitHub with cache-busting timestamp
                Arvn:Notify({Title = "Skinchanger", Content = "Fetching from GitHub..."})
                local okHttp, content = pcall(function()
                    return game:HttpGet("https://raw.githubusercontent.com/alvin12127/roblox_bloxstrike_SC/main/init.lua?t=" .. tostring(os.time()))
                end)
                if okHttp and content and #content > 0 then
                    local fn, loadErr = loadstring(content)
                    if fn then
                        local okExec, execErr = pcall(fn)
                        if okExec then
                            Arvn:Notify({Title = "Skinchanger", Content = "Loaded successfully!", Kind = "Success"})
                            return
                        else
                            warn("[Bloxstrike] Skinchanger execution error:", execErr)
                            Arvn:Notify({Title = "Error", Content = tostring(execErr), Kind = "Error"})
                            return
                        end
                    end
                end

                Arvn:Notify({Title = "Error", Content = "Failed to fetch skinchanger from GitHub", Kind = "Error"})
            end)
        end
    })

    -- settings tab
    local SettingsTab = Main:Tab({Name = "Settings", Icon = "settings"})
    local MenuGroup = SettingsTab:Section("Keybinds")

    MenuGroup:Keybind({
        Name = "Menu Key",
        Default = (Config.TOGGLE_UI_KEY and Config.TOGGLE_UI_KEY.Name) or "Insert",
        Callback = function(key)
            local k = (key ~= "None") and Enum.KeyCode[key] or nil
            updateSetting("TOGGLE_UI_KEY", k)
        end
    })

    MenuGroup:Keybind({
        Name = "Silent aim bind",
        Default = (type(Config.TOGGLE_AIM_KEY) == "string" and Config.TOGGLE_AIM_KEY) or (Config.TOGGLE_AIM_KEY and Config.TOGGLE_AIM_KEY.Name) or "None",
        Mode = Config.AIM_BIND_MODE or "Hold",
        Callback = function(key)
            local k = nil
            if key and key ~= "None" then
                if key == "MB1" or key == "MB2" or key == "MB3" then
                    k = key
                else
                    k = Enum.KeyCode[key] or key
                end
            end
            updateSetting("TOGGLE_AIM_KEY", k)
        end
    })

    MenuGroup:Dropdown({
        Name = "Aim bind mode",
        Values = {"Toggle", "Hold"},
        Default = Config.AIM_BIND_MODE or "Toggle",
        Description = "Toggle: Press key to toggle silent aim on/off\nHold: Hold key to activate silent aim",
        Callback = function(value)
            updateSetting("AIM_BIND_MODE", value)
        end
    })

    MenuGroup:Keybind({
        Name = "Master ESP bind",
        Default = (Config.TOGGLE_ESP_KEY and Config.TOGGLE_ESP_KEY.Name) or "None",
        Callback = function(key)
            local k = (key ~= "None") and Enum.KeyCode[key] or nil
            updateSetting("TOGGLE_ESP_KEY", k)
        end
    })

    MenuGroup:Keybind({
        Name = "Kill script",
        Default = (Config.UNLOAD_KEY and Config.UNLOAD_KEY.Name) or "K",
        Callback = function(key)
            local k = (key ~= "None") and Enum.KeyCode[key] or nil
            updateSetting("UNLOAD_KEY", k)
        end
    })

    local ActionsGroup = SettingsTab:Section({Name = "Actions", Side = "Right"})

    ActionsGroup:Button({
        Name = "Reset defaults",
        Callback = function()
            Config.reset()
            Arvn:Notify({Title = "Settings", Content = "Reset to defaults", Kind = "Success"})
        end
    })

    ActionsGroup:Button({
        Name = "Unload suite",
        Callback = function()
            if type(unloadCallback) == "function" then
                unloadCallback()
            elseif _G.__bloxstrikeJanitor then
                _G.__bloxstrikeJanitor()
            end
        end
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
        if Arvn and Arvn.IsPickingKey then return end
        if UserInputService:GetFocusedTextBox() then return end

        if matchesAimKey(input) then
            if Config.AIM_BIND_MODE == "Toggle" then
                local nextState = not Config.SILENT_AIM_ENABLED
                updateSetting("SILENT_AIM_ENABLED", nextState)
            end
        elseif Config.TOGGLE_ESP_KEY and input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Config.TOGGLE_ESP_KEY then
            local nextState = not Config.ESP_ENABLED
            updateSetting("ESP_ENABLED", nextState)
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
                if Arvn and Arvn.Toggled then
                    return
                end
                return origEquip(slot, index, ...)
            end

            if origEquipLocal then
                InventoryController.equipLocal = function(slot, index, ...)
                    if Arvn and Arvn.Toggled then
                        return
                    end
                    return origEquipLocal(slot, index, ...)
                end
            end
        end
    end)

    -- Show menu on startup
    if Config.MENU_OPEN ~= false then
        pcall(function()
            if (not Arvn.Toggled) and Arvn.Toggle then
                Arvn:Toggle()
            end
        end)
    end

    Arvn:Notify({Title = "Bloxstrike", Content = "v2.5 Loaded!", Kind = "Success"})
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

    -- Hide the menu instead of unloading the entire UI library
    if Arvn and Arvn.Toggled then
        pcall(Arvn.Toggle, Arvn)
    end

    UIManager.Library = nil
    UIManager.Window = nil
    UIManager.Initialized = false
end

return UIManager