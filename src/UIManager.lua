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
    if type(WeaponEngine) == "function" and unloadCallback == nil then
        unloadCallback = WeaponEngine
        WeaponEngine = nil
    end

    if UIManager.Initialized then return end
    UIManager.Initialized = true
    UIManager.Library = Arvn

    if not Arvn or type(Arvn.CreateWindow) ~= "function" then
        warn("[Bloxstrike] Arvn library not loaded properly")
        UIManager.Initialized = false
        UIManager.Library = nil
        return
    end

    -- auto save debounce
    local saveDebounce = nil
    local function queueAutoSave()
        if saveDebounce then task.cancel(saveDebounce) end
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

    -- The skin catalog needs room for a 4-wide card grid plus the toolbars.
    -- arvn's default window clipped the third row and squeezed the hint text.
    pcall(function() Window:SetSize(760, 560) end)

    local Main = Window:Group("Main")

    -- ==========================================
    -- AIM TAB
    -- ==========================================
    local AimTab = Main:Tab({Name = "Aim", Icon = "crosshair"})
    local AimSection = AimTab:Section("Silent Aim")
    local AimAccuracy = AimTab:Section({Name = "Accuracy & FOV", Side = "Right"})

    AimSection:Toggle({
        Name = "Silent aim",
        Default = (Config.SILENT_AIM_ENABLED ~= false),
        Description = "Redirects bullets directly to optimal enemy hitbox within FOV cone",
        Callback = function(on) updateSetting("SILENT_AIM_ENABLED", on) end
    })
    AimSection:Toggle({
        Name = "Keep target lock",
        Default = (Config.KEEP_TARGET_LOCK ~= false),
        Description = "Maintains lock on current target while firing",
        Callback = function(on) updateSetting("KEEP_TARGET_LOCK", on) end
    })
    AimSection:Toggle({
        Name = "Occlusion check",
        Default = (Config.AIM_OCCLUSION_CHECK == true),
        Description = "Prevents bullet redirection if all hitboxes of a target are occluded behind walls",
        Callback = function(on) updateSetting("AIM_OCCLUSION_CHECK", on) end
    })
    AimSection:Dropdown({
        Name = "Target priority",
        Values = {"Auto", "Head", "Torso", "Random"},
        Default = Config.TARGET_PRIORITY or "Auto",
        Description = "Auto: Lethal damage calculation and occlusion scanner\nHead: Strictly headshots\nTorso: Upper and lower torso\nRandom: Random visible hitbox",
        Callback = function(v) updateSetting("TARGET_PRIORITY", v) end
    })

    AimAccuracy:Toggle({
        Name = "Hit chance",
        Default = (Config.HIT_CHANCE_ENABLED == true),
        Description = "Adds a miss chance per bullet.",
        Callback = function(on) updateSetting("HIT_CHANCE_ENABLED", on) end
    })
    AimAccuracy:Slider({
        Name = "Chance",
        Min = 0, Max = 100, Default = Config.HIT_CHANCE or 100,
        Suffix = "%",
        Description = "100 = every shot is redirected, 0 = never redirects",
        Callback = function(v) updateSetting("HIT_CHANCE", v) end
    })
    AimAccuracy:Slider({
        Name = "FOV angle",
        Min = 1, Max = 180, Default = Config.FOV_DEG or 30,
        Suffix = "°",
        Description = "Maximum angle from the crosshair.",
        Callback = function(v) updateSetting("FOV_DEG", v) end
    })

    -- Hit Sound
    local CUSTOM_SOUND = (HitSound and HitSound.CUSTOM_VALUE) or "Custom (asset ID)"
    local function reportHitSoundSource()
        if not HitSound or not HitSound.isReady or HitSound.isReady() then return end
        Arvn:Notify({Title = "Hit Sound", Content = "Source not found", Kind = "Error"})
    end

    local AimHitSound = AimTab:Section({Name = "Hit Sound", Side = "Right"})

    AimHitSound:Toggle({
        Name = "Hit sound",
        Default = (Config.HITSOUND_ENABLED == true),
        Description = "Plays a sound whenever one of your bullets registers a hit",
        Callback = function(on)
            updateSetting("HITSOUND_ENABLED", on)
            if HitSound and HitSound.refresh then HitSound.refresh(Config) end
            if on then reportHitSoundSource() end
        end
    })

    local hitSoundValues = (HitSound and HitSound.getLabels) and HitSound.getLabels() or {}
    table.insert(hitSoundValues, CUSTOM_SOUND)

    local function labelForKey(key)
        return key and HitSound and HitSound.getLabel and HitSound.getLabel(key)
    end

    local hitSoundDefault = hitSoundValues[1]
    if (type(Config.HITSOUND_ASSET_ID) == "string") and (#Config.HITSOUND_ASSET_ID > 0) then
        hitSoundDefault = CUSTOM_SOUND
    else
        local savedLabel = labelForKey(Config.HITSOUND_FILE)
        if savedLabel then hitSoundDefault = savedLabel end
    end

    local hitSoundVolumeTask = nil

    AimHitSound:Dropdown({
        Name = "Sound",
        Values = hitSoundValues,
        Default = hitSoundDefault,
        Callback = function(v)
            local key = (HitSound and HitSound.getKeyByLabel) and HitSound.getKeyByLabel(v) or nil
            if key then
                updateSetting("HITSOUND_FILE", key)
                updateSetting("HITSOUND_ASSET_ID", "")
            else
                updateSetting("HITSOUND_FILE", "")
            end
            if HitSound and HitSound.refresh then HitSound.refresh(Config) end
            reportHitSoundSource()
        end
    })

    AimHitSound:Slider({
        Name = "Volume",
        Min = 0, Max = 100, Default = Config.HITSOUND_VOLUME or 70,
        Suffix = "%",
        Callback = function(v)
            updateSetting("HITSOUND_VOLUME", v)
            if HitSound then HitSound.setVolume((tonumber(v) or 0) / 100) end
            if hitSoundVolumeTask then task.cancel(hitSoundVolumeTask) end
            hitSoundVolumeTask = task.delay(0.4, function()
                hitSoundVolumeTask = nil
                if HitSound and HitSound.build then HitSound.build(Config) end
            end)
        end
    })

    AimHitSound:Input({
        Name = "Roblox asset ID",
        Default = Config.HITSOUND_ASSET_ID or "",
        Numeric = false,
        Finished = true,
        Callback = function(v)
            local raw = tostring(v or "")
            if HitSound and HitSound.setAssetId then HitSound.setAssetId(Config, Config.HITSOUND_FILE, raw) end
            if HitSound and HitSound.refresh then HitSound.refresh(Config) end
            reportHitSoundSource()
        end
    })

    AimHitSound:Button({
        Name = "Test sound",
        Callback = function()
            if HitSound and HitSound.play then
                HitSound.play()
                reportHitSoundSource()
            end
        end
    })

    -- ==========================================
    -- WEAPONS TAB
    -- ==========================================
    local WeaponsTab = Main:Tab({Name = "Weapons", Icon = "crosshair"})
    local WeaponFire = WeaponsTab:Section("Fire Rate & Trigger")
    local WeaponPen = WeaponsTab:Section({Name = "Penetration & Wallbang", Side = "Right"})
    local WeaponAcc = WeaponsTab:Section({Name = "Recoil & Spread", Side = "Right"})

    WeaponFire:Toggle({
        Name = "Custom fire rate (RPM)",
        Default = (Config.CUSTOM_RPM_ENABLED == true),
        Description = "Overrides the fire rate for all weapons",
        Callback = function(on)
            updateSetting("CUSTOM_RPM_ENABLED", on)
            if WeaponEngine and WeaponEngine.sync then WeaponEngine.sync(Config) end
        end
    })
    WeaponFire:Slider({
        Name = "Fire rate (RPM)",
        Min = 60, Max = 3000, Default = Config.CUSTOM_RPM_VALUE or 600,
        Suffix = " RPM",
        Callback = function(v)
            updateSetting("CUSTOM_RPM_VALUE", v)
            if WeaponEngine and WeaponEngine.sync then WeaponEngine.sync(Config) end
        end
    })
    WeaponFire:Toggle({
        Name = "Force full auto",
        Default = (Config.FORCE_FULL_AUTO == true),
        Description = "Converts semi-automatic weapons to full-automatic",
        Callback = function(on)
            updateSetting("FORCE_FULL_AUTO", on)
            if WeaponEngine and WeaponEngine.sync then WeaponEngine.sync(Config) end
        end
    })
    WeaponFire:Toggle({
        Name = "Instant reload",
        Default = (Config.INSTANT_RELOAD == true),
        Description = "Makes reload animations finish instantly",
        Callback = function(on) updateSetting("INSTANT_RELOAD", on) end
    })

    WeaponPen:Toggle({
        Name = "Infinite wallbang",
        Default = (Config.WALLBANG_ENABLED == true),
        Description = "Fabricates bullet hits through any wall",
        Callback = function(on) updateSetting("WALLBANG_ENABLED", on) end
    })

    WeaponAcc:Toggle({
        Name = "No recoil",
        Default = (Config.NO_RECOIL == true),
        Description = "Zeroes every recoil field in the weapon database",
        Callback = function(on)
            updateSetting("NO_RECOIL", on)
            if WeaponEngine and WeaponEngine.sync then WeaponEngine.sync(Config) end
        end
    })
    WeaponAcc:Toggle({
        Name = "No spread",
        Default = (Config.NO_SPREAD == true),
        Description = "Removes bullet deviation",
        Callback = function(on)
            updateSetting("NO_SPREAD", on)
            if WeaponEngine and WeaponEngine.sync then WeaponEngine.sync(Config) end
        end
    })

    -- ==========================================
    -- VISUALS TAB
    -- ==========================================
    local VisualsTab = Main:Tab({Name = "Visuals", Icon = "eye"})
    local EspMain = VisualsTab:Section("ESP Elements")
    local VisualSettings = VisualsTab:Section({Name = "FOV & Utilities", Side = "Right"})

    EspMain:Toggle({
        Name = "Enable ESP",
        Default = (Config.ESP_ENABLED ~= false),
        Description = "Master switch for all visual ESP features",
        Callback = function(on) updateSetting("ESP_ENABLED", on) end
    })
    EspMain:Toggle({
        Name = "Skeleton ESP",
        Default = (Config.SKELETON_ENABLED ~= false),
        Description = "Renders 3D bone skeletons and health bars",
        Callback = function(on) updateSetting("SKELETON_ENABLED", on) end
    })
    EspMain:Toggle({
        Name = "Name ESP",
        Default = (Config.NAME_ESP_ENABLED ~= false),
        Description = "Player name above the skeleton",
        Callback = function(on) updateSetting("NAME_ESP_ENABLED", on) end
    })
    EspMain:Toggle({
        Name = "Equipped item ESP",
        Default = (Config.ITEM_ESP_ENABLED ~= false),
        Description = "Currently held weapon below the skeleton",
        Callback = function(on) updateSetting("ITEM_ESP_ENABLED", on) end
    })
    EspMain:Toggle({
        Name = "View angle",
        Default = (Config.VIEWANGLE_ENABLED ~= false),
        Description = "Renders head look direction ray",
        Callback = function(on) updateSetting("VIEWANGLE_ENABLED", on) end
    })
    EspMain:Toggle({
        Name = "Offscreen arrows",
        Default = (Config.OFFSCREEN_ARROWS ~= false),
        Description = "Directional pointers for out-of-view enemies",
        Callback = function(on) updateSetting("OFFSCREEN_ARROWS", on) end
    })
    EspMain:Toggle({
        Name = "Visualize target part",
        Default = (Config.BODYPART_TARGET_HL ~= false),
        Description = "Highlights active targeted limb",
        Callback = function(on) updateSetting("BODYPART_TARGET_HL", on) end
    })
    EspMain:Toggle({
        Name = "Disable teammates",
        Default = (Config.DISABLE_TEAMMATES == true),
        Description = "Hides ESP for friendly teammates",
        Callback = function(on) updateSetting("DISABLE_TEAMMATES", on) end
    })
    EspMain:Toggle({
        Name = "Occlusion check",
        Default = (Config.OCCLUSION_CHECK_ENABLED ~= false),
        Description = "Dims skeleton color when behind walls",
        Callback = function(on) updateSetting("OCCLUSION_CHECK_ENABLED", on) end
    })
    EspMain:Toggle({
        Name = "Spectator counter",
        Default = (Config.SPECTATE_CHECKER_ENABLED ~= false),
        Description = "HUD widget for players spectating you",
        Callback = function(on) updateSetting("SPECTATE_CHECKER_ENABLED", on) end
    })

    VisualSettings:Toggle({
        Name = "Show FOV circle",
        Default = (Config.FOV_CIRCLE_ENABLED ~= false),
        Description = "Renders screen-center FOV boundary",
        Callback = function(on) updateSetting("FOV_CIRCLE_ENABLED", on) end
    })
    VisualSettings:Slider({
        Name = "FOV opacity",
        Min = 5, Max = 100,
        Default = math.floor((Config.FOV_CIRCLE_TRANSPARENCY or 0.5) * 100),
        Suffix = "%",
        Callback = function(v) updateSetting("FOV_CIRCLE_TRANSPARENCY", v / 100) end
    })
    VisualSettings:Toggle({
        Name = "Box ESP",
        Default = (Config.BOX_ESP_ENABLED ~= false),
        Description = "Bounding cube around every enemy",
        Callback = function(on) updateSetting("BOX_ESP_ENABLED", on) end
    })
    VisualSettings:Toggle({
        Name = "Corner only",
        Default = (Config.BOX_ESP_CORNERS_ONLY ~= false),
        Description = "Only the four corners of the box",
        Callback = function(on) updateSetting("BOX_ESP_CORNERS_ONLY", on) end
    })
    VisualSettings:Toggle({
        Name = "C4 ESP",
        Default = (Config.C4_ESP_ENABLED ~= false),
        Description = "Marks bomb carrier and bomb itself",
        Callback = function(on) updateSetting("C4_ESP_ENABLED", on) end
    })
    VisualSettings:Toggle({
        Name = "Grenade ESP",
        Default = (Config.GRENADE_ESP_ENABLED == true),
        Description = "Marks dropped grenades / utility with distance",
        Callback = function(on) updateSetting("GRENADE_ESP_ENABLED", on) end
    })
    VisualSettings:Slider({
        Name = "Grenade box size",
        Min = 8, Max = 60,
        Default = Config.GRENADE_ESP_BOX_SIZE or 26,
        Suffix = "px",
        Callback = function(v) updateSetting("GRENADE_ESP_BOX_SIZE", v) end
    })
    VisualSettings:Slider({
        Name = "Grenade max distance",
        Min = 50, Max = 2000, Step = 25,
        Default = Config.GRENADE_ESP_MAX_DISTANCE or 800,
        Suffix = "m",
        Callback = function(v) updateSetting("GRENADE_ESP_MAX_DISTANCE", v) end
    })
    VisualSettings:Toggle({
        Name = "Anti-flash",
        Default = (Config.ANTI_FLASH_ENABLED ~= false),
        Description = "Neutralizes blinding white screen flashes",
        Callback = function(on) updateSetting("ANTI_FLASH_ENABLED", on) end
    })
    VisualSettings:Slider({
        Name = "Flash opacity",
        Min = 5, Max = 100,
        Default = math.floor((Config.ANTI_FLASH_TRANSPARENCY or 0.85) * 100),
        Suffix = "%",
        Callback = function(v) updateSetting("ANTI_FLASH_TRANSPARENCY", v / 100) end
    })

    -- Bullet Tracer
    local TracerBox = VisualsTab:Section({Name = "Bullet Tracer", Side = "Right"})

    TracerBox:Toggle({
        Name = "Enable tracers",
        Default = (Config.BULLET_TRACER_ENABLED == true),
        Description = "Draws the flight path of every bullet",
        Callback = function(on) updateSetting("BULLET_TRACER_ENABLED", on) end
    })
    TracerBox:ColorPicker({
        Name = "Tracer color",
        Default = Config.BULLET_TRACER_COLOR or Color3.fromRGB(186, 140, 255),
        Callback = function(v) updateSetting("BULLET_TRACER_COLOR", v) end
    })
    TracerBox:Slider({
        Name = "Line thickness",
        Min = 0.1, Max = 6, Default = Config.BULLET_TRACER_THICKNESS or 1.5,
        Suffix = " px",
        Callback = function(v) updateSetting("BULLET_TRACER_THICKNESS", v) end
    })
    TracerBox:Slider({
        Name = "Fade time",
        Min = 1, Max = 30,
        Default = (Config.BULLET_TRACER_DURATION or 0.6) * 10,
        Suffix = " (x0.1s)",
        Callback = function(v) updateSetting("BULLET_TRACER_DURATION", v / 10) end
    })

    -- Chams
    local ChamsBox = VisualsTab:Section({Name = "Chams", Side = "Right"})

    ChamsBox:Toggle({
        Name = "Enable chams",
        Default = (Config.CHAMS_ENABLED == true),
        Description = "Colors enemy characters through walls",
        Callback = function(on) updateSetting("CHAMS_ENABLED", on) end
    })
    ChamsBox:Toggle({
        Name = "Through walls",
        Default = (Config.CHAMS_THROUGH_WALLS ~= false),
        Description = "Render chams through walls",
        Callback = function(on) updateSetting("CHAMS_THROUGH_WALLS", on) end
    })
    ChamsBox:Dropdown({
        Name = "Mode",
        Values = {"Fill", "Outline", "Both"},
        Default = Config.CHAMS_MODE or "Both",
        Description = "Fill: Only fill\nOutline: Only outline\nBoth: Fill and outline",
        Callback = function(v) updateSetting("CHAMS_MODE", v) end
    })
    ChamsBox:Dropdown({
        Name = "Style",
        Values = {"Solid", "Pulse", "Rainbow", "Gradient", "Wireframe", "Distance"},
        Default = Config.CHAMS_STYLE or "Solid",
        Description = "Solid: Static color\nPulse: Pulsing transparency\nRainbow: Cycling hue\nGradient: Color blend\nWireframe: Outline only\nDistance: Distance-based color",
        Callback = function(v) updateSetting("CHAMS_STYLE", v) end
    })
    ChamsBox:ColorPicker({
        Name = "Primary color",
        Default = Config.CHAMS_COLOR or Color3.fromRGB(255, 60, 60),
        Callback = function(v) updateSetting("CHAMS_COLOR", v) end
    })
    ChamsBox:ColorPicker({
        Name = "Secondary color",
        Default = Config.CHAMS_COLOR_SECONDARY or Color3.fromRGB(60, 200, 255),
        Callback = function(v) updateSetting("CHAMS_COLOR_SECONDARY", v) end
    })
    ChamsBox:Slider({
        Name = "Fill transparency",
        Min = 0, Max = 1, Default = Config.CHAMS_FILL_TRANSPARENCY or 0.5,
        Callback = function(v) updateSetting("CHAMS_FILL_TRANSPARENCY", v) end
    })
    ChamsBox:Slider({
        Name = "Outline transparency",
        Min = 0, Max = 1, Default = Config.CHAMS_OUTLINE_TRANSPARENCY or 0.8,
        Callback = function(v) updateSetting("CHAMS_OUTLINE_TRANSPARENCY", v) end
    })
    ChamsBox:Slider({
        Name = "Pulse speed",
        Min = 0.5, Max = 10, Default = Config.CHAMS_PULSE_SPEED or 3,
        Suffix = "x",
        Callback = function(v) updateSetting("CHAMS_PULSE_SPEED", v) end
    })
    ChamsBox:Slider({
        Name = "Gradient speed",
        Min = 0.5, Max = 10, Default = Config.CHAMS_GRADIENT_SPEED or 2,
        Suffix = "x",
        Callback = function(v) updateSetting("CHAMS_GRADIENT_SPEED", v) end
    })
    ChamsBox:Slider({
        Name = "Distance near",
        Min = 10, Max = 500, Default = Config.CHAMS_DISTANCE_NEAR or 100,
        Suffix = " s",
        Callback = function(v) updateSetting("CHAMS_DISTANCE_NEAR", v) end
    })
    ChamsBox:Slider({
        Name = "Distance far",
        Min = 100, Max = 3000, Default = Config.CHAMS_DISTANCE_FAR or 1500,
        Suffix = " s",
        Callback = function(v) updateSetting("CHAMS_DISTANCE_FAR", v) end
    })

    -- ==========================================
    -- MOVEMENT TAB
    -- ==========================================
    local MovementTab = Main:Tab({Name = "Movement", Icon = "move"})
    local MoveMain = MovementTab:Section("Bunny Hop")
    local AimControl = MovementTab:Section({Name = "Spin Bot & Anti Aim", Side = "Right"})

    MoveMain:Toggle({
        Name = "Bunny hop",
        Default = (Config.BHOP_ENABLED ~= false),
        Description = "Automatic jump execution via native MovementV2 physics",
        Callback = function(on) updateSetting("BHOP_ENABLED", on) end
    })
    MoveMain:Toggle({
        Name = "Auto jump",
        Default = (Config.BHOP_AUTO_JUMP ~= false),
        Description = "Automatically jumps when grounded",
        Callback = function(on) updateSetting("BHOP_AUTO_JUMP", on) end
    })
    MoveMain:Toggle({
        Name = "Auto strafe",
        Default = (Config.BHOP_AUTO_STRAFE ~= false),
        Description = "Automatically strafes in the air",
        Callback = function(on) updateSetting("BHOP_AUTO_STRAFE", on) end
    })
    MoveMain:Toggle({
        Name = "Fake duck",
        Default = (Config.FAKE_DUCK_ENABLED == true),
        Description = "Keep full walking speed while crouched (the crouch pose stays)",
        Callback = function(on) updateSetting("FAKE_DUCK_ENABLED", on) end
    })
    MoveMain:Slider({
        Name = "Strafe force",
        Min = 0.5, Max = 10, Default = Config.BHOP_STRAFE_FORCE or 2,
        Suffix = "x",
        Callback = function(v) updateSetting("BHOP_STRAFE_FORCE", v) end
    })
    MoveMain:Slider({
        Name = "Min speed",
        Min = 0, Max = 50, Default = Config.BHOP_MIN_SPEED or 10,
        Suffix = " s/s",
        Callback = function(v) updateSetting("BHOP_MIN_SPEED", v) end
    })
    MoveMain:Dropdown({
        Name = "Mode",
        Values = {"Legit", "Rage"},
        Default = Config.BHOP_MODE or "Legit",
        Description = "Legit: Wait for space input\nRage: Auto hop without input",
        Callback = function(v) updateSetting("BHOP_MODE", v) end
    })
    MoveMain:Toggle({
        Name = "Teleport boost",
        Default = (Config.BHOP_TELEPORT_BOOST == true),
        Description = "Boosts movement on jump",
        Callback = function(on) updateSetting("BHOP_TELEPORT_BOOST", on) end
    })
    MoveMain:Slider({
        Name = "Teleport distance",
        Min = 0.05, Max = 1, Default = Config.BHOP_TELEPORT_DISTANCE or 0.5,
        Callback = function(v) updateSetting("BHOP_TELEPORT_DISTANCE", v) end
    })

    AimControl:Toggle({
        Name = "Spin bot",
        Default = (Config.SPINBOT_ENABLED == true),
        Description = "Spins the local rig continuously",
        Callback = function(on) updateSetting("SPINBOT_ENABLED", on) end
    })
    AimControl:Slider({
        Name = "Spin speed",
        Min = 60, Max = 3000, Default = Config.SPINBOT_RPM or 600,
        Suffix = " RPM",
        Callback = function(v) updateSetting("SPINBOT_RPM", v) end
    })
    AimControl:Toggle({
        Name = "Anti aim",
        Default = (Config.ANTIAIM_ENABLED == true),
        Description = "Tilts the local rig so the head is harder to read",
        Callback = function(on) updateSetting("ANTIAIM_ENABLED", on) end
    })
    AimControl:Dropdown({
        Name = "Yaw base",
        Values = {"Off", "Spin", "Jitter", "Random"},
        Default = Config.ANTIAIM_YAW_BASE or "Off",
        Description = "Off: No yaw modification\nSpin: Continuous rotation\nJitter: Random jitter\nRandom: Random yaw",
        Callback = function(v) updateSetting("ANTIAIM_YAW_BASE", v) end
    })
    AimControl:Slider({
        Name = "Yaw offset",
        Min = -180, Max = 180, Default = Config.ANTIAIM_YAW_OFFSET or 0,
        Suffix = "°",
        Callback = function(v) updateSetting("ANTIAIM_YAW_OFFSET", v) end
    })
    AimControl:Slider({
        Name = "Spin speed",
        Min = 30, Max = 720, Default = Config.ANTIAIM_SPIN_SPEED or 360,
        Suffix = "°/s",
        Callback = function(v) updateSetting("ANTIAIM_SPIN_SPEED", v) end
    })
    AimControl:Slider({
        Name = "Jitter offset",
        Min = 5, Max = 90, Default = Config.ANTIAIM_JITTER_OFFSET or 30,
        Suffix = "°",
        Callback = function(v) updateSetting("ANTIAIM_JITTER_OFFSET", v) end
    })
    AimControl:Slider({
        Name = "Pitch",
        Min = 0, Max = 120, Default = Config.ANTIAIM_PITCH or 60,
        Suffix = "°",
        Callback = function(v) updateSetting("ANTIAIM_PITCH", v) end
    })

    -- ==========================================
    -- WORLD TAB
    -- ==========================================
    local WorldTab = Main:Tab({Name = "World", Icon = "sun"})
    local CameraBox = WorldTab:Section("Camera")
    local LightingBox = WorldTab:Section({Name = "Lighting", Side = "Right"})
    local WorldModsBox = WorldTab:Section({Name = "World Mods", Side = "Right"})
    local MapColorBox = WorldTab:Section({Name = "Map Color", Side = "Right"})
    local ThirdPersonBox = WorldTab:Section({Name = "Third Person", Side = "Right"})

    CameraBox:Toggle({
        Name = "Custom camera FOV",
        Default = (Config.CAMERA_FOV_ENABLED == true),
        Description = "Overrides the camera field of view",
        Callback = function(on) updateSetting("CAMERA_FOV_ENABLED", on) end
    })
    CameraBox:Slider({
        Name = "FOV",
        Min = 30, Max = 120, Default = Config.CAMERA_FOV_VALUE or 90,
        Suffix = "°",
        Callback = function(v) updateSetting("CAMERA_FOV_VALUE", v) end
    })

    LightingBox:Toggle({
        Name = "Custom clock time",
        Default = (Config.CLOCK_TIME_ENABLED == true),
        Description = "Sets the in-game time",
        Callback = function(on) updateSetting("CLOCK_TIME_ENABLED", on) end
    })
    LightingBox:Slider({
        Name = "Time",
        Min = 0, Max = 24, Default = Config.CLOCK_TIME or 14,
        Suffix = "h",
        Callback = function(v) updateSetting("CLOCK_TIME", v) end
    })
    LightingBox:Toggle({
        Name = "Custom brightness",
        Default = (Config.BRIGHTNESS_ENABLED == true),
        Description = "Overrides the game brightness",
        Callback = function(on) updateSetting("BRIGHTNESS_ENABLED", on) end
    })
    LightingBox:Slider({
        Name = "Brightness",
        Min = 0, Max = 10, Default = Config.BRIGHTNESS or 2,
        Callback = function(v) updateSetting("BRIGHTNESS", v) end
    })
    LightingBox:Toggle({
        Name = "Custom ambient",
        Default = (Config.AMBIENT_ENABLED == true),
        Description = "Overrides the ambient color",
        Callback = function(on) updateSetting("AMBIENT_ENABLED", on) end
    })
    LightingBox:ColorPicker({
        Name = "Ambient color",
        Default = Config.AMBIENT_COLOR or Color3.fromRGB(100, 100, 100),
        Callback = function(v) updateSetting("AMBIENT_COLOR", v) end
    })
    LightingBox:Toggle({
        Name = "Outdoor ambient",
        Default = (Config.OUTDOOR_AMBIENT_ENABLED == true),
        Description = "Overrides the outdoor ambient color",
        Callback = function(on) updateSetting("OUTDOOR_AMBIENT_ENABLED", on) end
    })
    LightingBox:ColorPicker({
        Name = "Outdoor color",
        Default = Config.OUTDOOR_AMBIENT_COLOR or Color3.fromRGB(100, 100, 100),
        Callback = function(v) updateSetting("OUTDOOR_AMBIENT_COLOR", v) end
    })

    WorldModsBox:Toggle({
        Name = "Fullbright",
        Default = (Config.FULLBRIGHT == true),
        Description = "Removes all shadows",
        Callback = function(on) updateSetting("FULLBRIGHT", on) end
    })
    WorldModsBox:Toggle({
        Name = "No fog",
        Default = (Config.NO_FOG == true),
        Description = "Removes fog from the game",
        Callback = function(on) updateSetting("NO_FOG", on) end
    })
    WorldModsBox:Toggle({
        Name = "No textures",
        Default = (Config.NO_TEXTURES == true),
        Description = "Removes textures from map parts",
        Callback = function(on) updateSetting("NO_TEXTURES", on) end
    })
    WorldModsBox:Toggle({
        Name = "Remove grass",
        Default = (Config.REMOVE_GRASS == true),
        Description = "Removes grass decoration from terrain",
        Callback = function(on) updateSetting("REMOVE_GRASS", on) end
    })
    WorldModsBox:Toggle({
        Name = "Custom skybox",
        Default = (Config.SKYBOX_ENABLED == true),
        Description = "Replaces the game skybox",
        Callback = function(on) updateSetting("SKYBOX_ENABLED", on) end
    })

    MapColorBox:Toggle({
        Name = "Enable map color",
        Default = (Config.MAP_COLOR_ENABLED == true),
        Description = "Tints the map with a custom color",
        Callback = function(on) updateSetting("MAP_COLOR_ENABLED", on) end
    })
    MapColorBox:Dropdown({
        Name = "Mode",
        Values = {"Tint", "Ambient", "Both", "Saturation"},
        Default = Config.MAP_COLOR_MODE or "Tint",
        Description = "Tint: Part colors\nAmbient: Lighting ambient\nBoth: Tint and ambient\nSaturation: Color correction saturation",
        Callback = function(v) updateSetting("MAP_COLOR_MODE", v) end
    })
    MapColorBox:ColorPicker({
        Name = "Map color",
        Default = Config.MAP_COLOR or Color3.fromRGB(255, 255, 255),
        Callback = function(v) updateSetting("MAP_COLOR", v) end
    })
    MapColorBox:Slider({
        Name = "Saturation",
        Min = -1, Max = 1, Default = Config.MAP_SATURATION or 0,
        Callback = function(v) updateSetting("MAP_SATURATION", v) end
    })

    ThirdPersonBox:Toggle({
        Name = "Third person",
        Default = (Config.THIRDPERSON_ENABLED == true),
        Description = "Pulls the camera back behind the rig. Mouse look is unaffected.",
        Callback = function(on) updateSetting("THIRDPERSON_ENABLED", on) end
    })
    ThirdPersonBox:Slider({
        Name = "Distance",
        Min = 4, Max = 40, Default = Config.THIRDPERSON_DISTANCE or 9,
        Suffix = " studs",
        Callback = function(v) updateSetting("THIRDPERSON_DISTANCE", v) end
    })
    ThirdPersonBox:Slider({
        Name = "Height offset",
        Min = -6, Max = 10, Default = Config.THIRDPERSON_HEIGHT or 0,
        Suffix = " studs",
        Callback = function(v) updateSetting("THIRDPERSON_HEIGHT", v) end
    })
    ThirdPersonBox:Toggle({
        Name = "Camera lock guard",
        Default = (Config.THIRDPERSON_GUARD ~= false),
        Description = "Wall collision raycast to keep camera out of walls",
        Callback = function(on) updateSetting("THIRDPERSON_GUARD", on) end
    })

    -- Post FX
    local PostFxBox = WorldTab:Section("Post FX")

    PostFxBox:Toggle({
        Name = "Bloom",
        Default = (Config.BLOOM_ENABLED == true),
        Description = "Adds a bloom effect to bright areas",
        Callback = function(on) updateSetting("BLOOM_ENABLED", on) end
    })
    PostFxBox:Slider({
        Name = "Intensity",
        Min = 0, Max = 5, Default = Config.BLOOM_INTENSITY or 1,
        Callback = function(v) updateSetting("BLOOM_INTENSITY", v) end
    })
    PostFxBox:Slider({
        Name = "Size",
        Min = 0, Max = 100, Default = Config.BLOOM_SIZE or 24,
        Callback = function(v) updateSetting("BLOOM_SIZE", v) end
    })
    PostFxBox:Toggle({
        Name = "Color correction",
        Default = (Config.COLOR_CORRECTION_ENABLED == true),
        Description = "Adjusts brightness, contrast, saturation and tint",
        Callback = function(on) updateSetting("COLOR_CORRECTION_ENABLED", on) end
    })
    PostFxBox:Slider({
        Name = "Brightness",
        Min = -1, Max = 1, Default = Config.CC_BRIGHTNESS or 0,
        Callback = function(v) updateSetting("CC_BRIGHTNESS", v) end
    })
    PostFxBox:Slider({
        Name = "Contrast",
        Min = -1, Max = 1, Default = Config.CC_CONTRAST or 0,
        Callback = function(v) updateSetting("CC_CONTRAST", v) end
    })
    PostFxBox:Slider({
        Name = "Saturation",
        Min = -1, Max = 1, Default = Config.CC_SATURATION or 0,
        Callback = function(v) updateSetting("CC_SATURATION", v) end
    })
    PostFxBox:ColorPicker({
        Name = "Tint color",
        Default = Config.CC_TINT_COLOR or Color3.fromRGB(255, 255, 255),
        Callback = function(v) updateSetting("CC_TINT_COLOR", v) end
    })
    PostFxBox:Toggle({
        Name = "Sun rays",
        Default = (Config.SUN_RAYS_ENABLED == true),
        Description = "Adds sun rays effect",
        Callback = function(on) updateSetting("SUN_RAYS_ENABLED", on) end
    })
    PostFxBox:Slider({
        Name = "Intensity",
        Min = 0, Max = 2, Default = Config.SUN_RAYS_INTENSITY or 0.25,
        Callback = function(v) updateSetting("SUN_RAYS_INTENSITY", v) end
    })
    PostFxBox:Toggle({
        Name = "Motion blur",
        Default = (Config.MOTION_BLUR_ENABLED == true),
        Description = "Adds motion blur effect",
        Callback = function(on) updateSetting("MOTION_BLUR_ENABLED", on) end
    })
    PostFxBox:Slider({
        Name = "Strength",
        Min = 0, Max = 10, Default = Config.MOTION_BLUR_STRENGTH or 1,
        Callback = function(v) updateSetting("MOTION_BLUR_STRENGTH", v) end
    })

    -- ==========================================
    -- SKINS TAB (hosts the working skin catalogs with 3D previews)
    -- ==========================================
    --
    -- The Knife / Gun / Glove catalogs build their own 3D skin previews and were
    -- written against LinoriaLib. They require:
    --   * Library:Create / Library:CreateLabel / Library:AddToRegistry
    --   * Library:Notify
    --   * Library.AccentColor / BackgroundColor / OutlineColor / MainColor /
    --     FontColor / Font
    --   * Tab.TabFrame (plus the optional Tab.LeftSide / Tab.RightSide)
    -- arvn implements none of those, so a compatibility shim is installed and the
    -- catalogs are handed a TabFrame that lives INSIDE this arvn tab. That keeps
    -- the working catalog architecture and the visual skin picker, but inside the
    -- single main cheat window.
    local SkinsTab = Main:Tab({Name = "Skins", Icon = "palette"})

    -- arvn theme snapshot, so the catalog chrome matches the main cheat
    local theme = {}
    pcall(function() theme = Arvn:GetTheme() end)
    if type(theme) ~= "table" then theme = {} end

    local function pick(key, fallback)
        local v = theme[key]
        if typeof(v) == "Color3" then return v end
        return fallback
    end

    local SkinShim = {
        AccentColor     = pick("Accent",  Color3.fromRGB(90, 155, 255)),
        BackgroundColor = pick("Card",    Color3.fromRGB(28, 28, 32)),
        OutlineColor    = pick("Field",   Color3.fromRGB(52, 52, 60)),
        MainColor       = pick("Hover",   Color3.fromRGB(38, 38, 44)),
        FontColor       = pick("Text",    Color3.fromRGB(238, 238, 245)),
        Font            = Enum.Font.Gotham,
    }

    function SkinShim:Create(Class, Properties)
        local obj = Instance.new(Class)
        if Properties then
            for k, v in pairs(Properties) do obj[k] = v end
        end
        return obj
    end

    function SkinShim:CreateLabel(Properties)
        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.BorderSizePixel = 0
        label.Font = Enum.Font.GothamMedium
        label.FontSize = 14
        label.Text = ""
        label.TextColor3 = SkinShim.FontColor
        if Properties then
            for k, v in pairs(Properties) do label[k] = v end
        end
        return label
    end

    -- Linoria uses this to live-update colours when the theme changes. arvn
    -- rebuilds its own chrome, so a no-op is enough to keep the catalogs alive.
    function SkinShim:AddToRegistry() end

    function SkinShim:Notify(content)
        if type(content) == "table" then
            return Arvn:Notify(content)
        end
        return Arvn:Notify({
            Title = "Skinchanger",
            Content = tostring(content),
            Kind = "Success"
        })
    end

    local SC_CATALOGS = {
        { key = "KnifeCatalog", label = "Knives" },
        { key = "GunCatalog",   label = "Guns" },
        { key = "GloveCatalog", label = "Gloves" },
    }

    -- Catalog grid area.
    --
    -- The catalog draws its own header bar ("Knife Models | Left-Click: ..."),
    -- which sat under this tab's toolbar and made the two overlap. That header is
    -- hidden after the catalog builds, and the panel starts at the grid instead.
    --
    -- The height is generous because a fixed 420 clipped the third card row.
    local PANEL_HEIGHT = 470
    local TOOLBAR_H = 32
    local ACTION_H = 30
    local skinsState = { holder = nil, built = false }

    -- Catalogs are built lazily, so refresh must tolerate one that has not been
    -- built yet: refresh() would otherwise call renderSkinCards on nil frames.
    local function refreshSkins()
        local sc = SkinChanger and SkinChanger.API
        if sc and sc.refresh then pcall(sc.refresh) end
        for _, entry in ipairs(SC_CATALOGS) do
            local catalog = SkinChanger and SkinChanger[entry.key]
            if catalog and catalog.refresh and catalog.Initialized then
                pcall(catalog.refresh)
            end
        end
    end

    local function buildSkinsPage(holder)
        -- arvn rebuilds its whole window on theme / metric changes, which destroys
        -- the old holder and runs this again. Skip while the previous build is
        -- still alive so the 3D viewports are not rebuilt needlessly.
        if skinsState.holder and skinsState.holder.Parent then return end
        skinsState.holder = holder
        skinsState.built = true

        local scAPI = SkinChanger and SkinChanger.API
        local scConfig = SkinChanger and SkinChanger.Config
        local scDb = SkinChanger and SkinChanger.Database

        if not scAPI or not scConfig or not scDb then
            SkinShim:CreateLabel({
                Size = UDim2.new(1, 0, 0, 24),
                Text = "Skinchanger modules failed to load - check the executor console.",
                TextColor3 = Color3.fromRGB(255, 90, 90),
                TextSize = 13,
                Parent = holder
            })
            return
        end

        -- ---------- toolbar ----------
        local bar = SkinShim:Create("Frame", {
            BackgroundTransparency = 1,
            Size = UDim2.new(1, 0, 0, TOOLBAR_H),
            ZIndex = 2,
            Parent = holder
        })

        SkinShim:Create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            HorizontalAlignment = Enum.HorizontalAlignment.Left,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            Padding = UDim.new(0, 6),
            SortOrder = Enum.SortOrder.LayoutOrder,
            Parent = bar
        })

        local navButtons = {}
        local panels = {}
        local built = {}

        -- The catalog renders its own header row and offsets the grid below it.
        -- That header duplicates this tab's toolbar, so it is hidden and the grid
        -- is moved up to reclaim the space. Without this the two label rows
        -- overlap and the grid starts half a row too low.
        local function tidyCatalogLayout(panel)
            if not panel then return end

            pcall(function()
                for _, d in ipairs(panel:GetDescendants()) do
                    -- header bars: short wide frames directly holding a title
                    if d:IsA("Frame") then
                        local h = d.AbsoluteSize.Y
                        if h and h <= 30 and d.AbsoluteSize.X > (panel.AbsoluteSize.X * 0.8) then
                            d.Visible = false
                        end
                    end
                end
            end)

            -- the grid's ScrollingFrame normally starts at Y=32 (below the
            -- header); move it to the top now that the header is gone
            pcall(function()
                for _, d in ipairs(panel:GetDescendants()) do
                    if d:IsA("ScrollingFrame") then
                        d.Position = UDim2.new(0, 0, 0, 0)
                        d.Size = UDim2.new(1, 0, 1, 0)
                    end
                end
            end)

            -- and let the container fill the panel
            pcall(function()
                for _, d in ipairs(panel:GetChildren()) do
                    if d:IsA("Frame") then
                        d.Position = UDim2.new(0, 0, 0, 0)
                        d.Size = UDim2.new(1, 0, 1, 0)
                    end
                end
            end)
        end

        -- Build one catalog on demand.
        --
        -- arvn builds EVERY page inside CreateWindow, so building all three
        -- catalogs up front created ~47 ViewportFrames (each with a cloned 3D
        -- model and a RenderStepped turntable connection) during load. That is
        -- enough to stall or crash the client, so only the requested catalog is
        -- ever built and the rest wait for their tab button.
        local function buildCatalog(index)
            if built[index] then return end

            local entry = SC_CATALOGS[index]
            local catalog = SkinChanger and SkinChanger[entry.key]
            local panel = panels[index]
            if not panel then return end

            -- A previous arvn rebuild may have destroyed the panel between the
            -- deferred call and now. Never build into a detached frame.
            if not panel.Parent then return end

            if (not catalog) or (type(catalog.init) ~= "function") then
                SkinShim:CreateLabel({
                    Size = UDim2.new(1, 0, 0, 24),
                    Text = entry.label .. " catalog unavailable.",
                    TextColor3 = Color3.fromRGB(255, 90, 90),
                    TextSize = 13,
                    Parent = panel
                })
                built[index] = true
                return
            end

            -- Drop the 3D viewport connections from any previous build first
            if type(catalog.cleanup) == "function" then pcall(catalog.cleanup) end
            catalog.Initialized = false
            catalog.CurrentView = "Models"

            local fakeTab = {
                TabFrame = panel,
                LeftSide = nil,
                RightSide = nil
            }

            local ok, err = pcall(catalog.init, fakeTab, scConfig, scAPI, SkinShim, scDb)
            if ok then
                built[index] = true
                tidyCatalogLayout(panel)
            else
                warn("[Bloxstrike] " .. entry.key .. " failed to build: " .. tostring(err))
                SkinShim:CreateLabel({
                    Size = UDim2.new(1, 0, 0, 40),
                    Text = entry.label .. " failed to build:\n" .. tostring(err),
                    TextColor3 = Color3.fromRGB(255, 90, 90),
                    TextSize = 12,
                    TextWrapped = true,
                    Parent = panel
                })
            end
        end

        for index, entry in ipairs(SC_CATALOGS) do
            local button = SkinShim:Create("TextButton", {
                BackgroundColor3 = (index == 1) and SkinShim.AccentColor or SkinShim.MainColor,
                BorderColor3 = SkinShim.OutlineColor,
                BorderSizePixel = 0,
                Size = UDim2.new(0, 104, 1, 0),
                Text = entry.label,
                TextColor3 = SkinShim.FontColor,
                TextSize = 13,
                Font = Enum.Font.GothamSemibold,
                LayoutOrder = index,
                ZIndex = 3,
                Parent = bar
            })

            SkinShim:Create("UICorner", {
                CornerRadius = UDim.new(0, 6),
                Parent = button
            })

            navButtons[index] = button

            panels[index] = SkinShim:Create("Frame", {
                BackgroundTransparency = 1,
                Position = UDim2.new(0, 0, 0, TOOLBAR_H + ACTION_H + 6),
                Size = UDim2.new(1, 0, 0, PANEL_HEIGHT),
                Visible = (index == 1),
                ZIndex = 2,
                Parent = holder
            })

            button.MouseButton1Click:Connect(function()
                for i = 1, #SC_CATALOGS do
                    if panels[i] then panels[i].Visible = (i == index) end
                    if navButtons[i] then
                        navButtons[i].BackgroundColor3 =
                            (i == index) and SkinShim.AccentColor or SkinShim.MainColor
                    end
                end

                -- Build lazily, one frame later so the tab switch is not blocked
                -- by creating dozens of viewports inside the click handler.
                task.defer(function()
                    if not panels[index] or not panels[index].Parent then return end
                    buildCatalog(index)
                end)
            end)
        end

        -- ---------- preset / action row ----------
        local actions = {
            { "All Special", "setAllSpecial" },
            { "All Random", "setAllRandom" },
            { "All Default", "setAllDefault" },
            { "Reroll", "rerollRandom" },
            { "Refresh", nil },
        }

        local actionBar = SkinShim:Create("Frame", {
            BackgroundTransparency = 1,
            Position = UDim2.new(0, 0, 0, TOOLBAR_H),
            Size = UDim2.new(1, 0, 0, ACTION_H),
            ZIndex = 2,
            Parent = holder
        })

        SkinShim:Create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            HorizontalAlignment = Enum.HorizontalAlignment.Left,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            Padding = UDim.new(0, 6),
            SortOrder = Enum.SortOrder.LayoutOrder,
            Parent = actionBar
        })

        for index, action in ipairs(actions) do
            local button = SkinShim:Create("TextButton", {
                BackgroundColor3 = SkinShim.MainColor,
                BorderColor3 = SkinShim.OutlineColor,
                BorderSizePixel = 0,
                Size = UDim2.new(0, 92, 1, 0),
                Text = action[1],
                TextColor3 = SkinShim.FontColor,
                TextSize = 12,
                Font = Enum.Font.Gotham,
                LayoutOrder = index,
                ZIndex = 3,
                Parent = actionBar
            })

            SkinShim:Create("UICorner", {
                CornerRadius = UDim.new(0, 6),
                Parent = button
            })

            button.MouseButton1Click:Connect(function()
                if action[2] then
                    if scAPI[action[2]] then pcall(scAPI[action[2]]) end
                end
                refreshSkins()
                SkinShim:Notify(action[1] .. " applied")
            end)
        end

        -- Only the first tab is built up front. The other two wait for their nav
        -- button, so a load never creates more than one catalog's viewports.
        task.defer(function()
            if panels[1] and panels[1].Parent then
                buildCatalog(1)
            end
        end)
    end

    -- CustomPage gives a full-bleed holder inside the tab. Fall back to a tall
    -- Custom row if an older arvn build ever lacks it.
    if type(SkinsTab.CustomPage) == "function" then
        SkinsTab:CustomPage(function(holder)
            pcall(buildSkinsPage, holder)
        end)
    else
        local skinsSection = SkinsTab:Section("Skin Changer")
        skinsSection:Custom({
            Name = "",
            Height = 560,
            Build = function(holder)
                pcall(buildSkinsPage, holder)
            end
        })
    end

    -- ==========================================
    -- SETTINGS TAB
    -- ==========================================
    local SettingsTab = Main:Tab({Name = "Settings", Icon = "settings"})
    local MenuGroup = SettingsTab:Section("Keybinds")
    local ActionsGroup = SettingsTab:Section({Name = "Actions", Side = "Right"})

    local defaultMenuKey = (Config.TOGGLE_UI_KEY and Config.TOGGLE_UI_KEY.Name) or "Insert"
    MenuGroup:Keybind({
        Name = "Menu Key",
        Default = defaultMenuKey,
        Callback = function(key)
            local k = (key ~= "None") and Enum.KeyCode[key] or nil
            updateSetting("TOGGLE_UI_KEY", k)
        end
    })

    local defaultAimKey = (type(Config.TOGGLE_AIM_KEY) == "string" and Config.TOGGLE_AIM_KEY)
        or (Config.TOGGLE_AIM_KEY and Config.TOGGLE_AIM_KEY.Name) or "None"
    MenuGroup:Keybind({
        Name = "Silent aim bind",
        Default = defaultAimKey,
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
        Description = "Toggle: Press key to toggle\nHold: Hold key to activate",
        Callback = function(v) updateSetting("AIM_BIND_MODE", v) end
    })

    local defaultEspKey = (Config.TOGGLE_ESP_KEY and Config.TOGGLE_ESP_KEY.Name) or "None"
    MenuGroup:Keybind({
        Name = "Master ESP bind",
        Default = defaultEspKey,
        Callback = function(key)
            local k = (key ~= "None") and Enum.KeyCode[key] or nil
            updateSetting("TOGGLE_ESP_KEY", k)
        end
    })

    local defaultUnloadKey = (Config.UNLOAD_KEY and Config.UNLOAD_KEY.Name) or "K"
    MenuGroup:Keybind({
        Name = "Unload key",
        Default = defaultUnloadKey,
        Callback = function(key)
            local k = (key ~= "None") and Enum.KeyCode[key] or nil
            updateSetting("UNLOAD_KEY", k)
        end
    })

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

    -- ==========================================
    -- KEY LISTENERS
    -- ==========================================
    local function matchesAimKey(input)
        local key = Config.TOGGLE_AIM_KEY
        if not key or key == "None" then return false end
        if typeof(key) == "EnumItem" and key.EnumType == Enum.KeyCode then
            return input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == key
        end
        if type(key) == "string" then
            if key == "MB1" then return input.UserInputType == Enum.UserInputType.MouseButton1 end
            if key == "MB2" then return input.UserInputType == Enum.UserInputType.MouseButton2 end
            if key == "MB3" then return input.UserInputType == Enum.UserInputType.MouseButton3 end
            if Enum.KeyCode[key] then
                return input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode[key]
            end
        end
        return false
    end

    local bindInputBegan = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        -- Never steal a keystroke while the menu is open or arvn is capturing a
        -- new keybind. arvn exposes IsOpen()/Toggle() but has no IsPickingKey(),
        -- so the open check is what guards the capture flow.
        pcall(function()
            if UIManager.Window and UIManager.Window:IsOpen() then return end
        end)
        if UserInputService:GetFocusedTextBox() then return end

        if matchesAimKey(input) then
            if Config.AIM_BIND_MODE == "Toggle" then
                updateSetting("SILENT_AIM_ENABLED", not Config.SILENT_AIM_ENABLED)
            end
        elseif Config.TOGGLE_ESP_KEY and input.UserInputType == Enum.UserInputType.Keyboard
            and input.KeyCode == Config.TOGGLE_ESP_KEY then
            updateSetting("ESP_ENABLED", not Config.ESP_ENABLED)
        end
    end)
    table.insert(UIManager.Connections, bindInputBegan)

    -- Show menu on startup
    if Config.MENU_OPEN ~= false then
        pcall(function()
            if Arvn.Toggle then
                Arvn:Toggle(true)
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

    -- Close the window so the cheat leaves nothing on screen behind it
    local Arvn = UIManager.Library
    if Arvn and Arvn.Toggle then
        pcall(function() Arvn:Toggle(false) end)
    end

    UIManager.Library = nil
    UIManager.Window = nil
    UIManager.Initialized = false
end

return UIManager