-- config and state
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local CONFIG_FOLDER = "Bloxstrike"
local CONFIG_FILE = "Bloxstrike/config.json"

local function ensureDirectory()
    if type(makefolder) == "function" then
        if type(isfolder) == "function" then
            if not isfolder(CONFIG_FOLDER) then
                pcall(makefolder, CONFIG_FOLDER)
            end
        else
            pcall(makefolder, CONFIG_FOLDER)
        end
    end
end

local Config = {
    -- aim
    SILENT_AIM_ENABLED = true,
    KEEP_TARGET_LOCK = true,
    FOV_DEG = 13,
    FALLOFF_REF = 500,
    FOV_CIRCLE_ENABLED = true,
    FOV_CIRCLE_TRANSPARENCY = 0.34,
    FOV_CIRCLE_COLOR = Color3.fromRGB(255, 255, 255),
    BODYPART_TARGET_HL = true,
    BODYPART_HL_COLOR = Color3.fromRGB(255, 255, 0),
    TARGET_PRIORITY = "Auto",
    AIM_OCCLUSION_CHECK = false,
    WALLBANG_ENABLED = false,

    -- hit chance
    HIT_CHANCE_ENABLED = false,
    HIT_CHANCE = 100,

    -- visuals
    ESP_ENABLED = true,
    ESP_HIGHLIGHT_ENABLED = false,
    SKELETON_ENABLED = true,
    NAME_ESP_ENABLED = true,
    ITEM_ESP_ENABLED = true,
    BOX_ESP_ENABLED = true,
    BOX_ESP_CORNERS_ONLY = true,
    C4_ESP_ENABLED = false,
    VIEWANGLE_ENABLED = true,
    OFFSCREEN_ARROWS = true,
    OFFSCREEN_ARROW_RADIUS = 0.72,
    OFFSCREEN_ARROW_SIZE = 13,
    OFFSCREEN_ARROW_MAX_DIST = 350,
    OFFSCREEN_ARROW_FADE_DIST = 80,
    DISABLE_TEAMMATES = true,
    OCCLUSION_CHECK_ENABLED = true,
    OCCLUDED_COLOR_FACTOR = 0.45,
    SPECTATE_CHECKER_ENABLED = true,

    -- movement
    BHOP_ENABLED = true,
    BHOP_AUTO_JUMP = true,
    BHOP_AUTO_STRAFE = true,
    BHOP_STRAFE_FORCE = 2,
    BHOP_MIN_SPEED = 10,
    BHOP_MODE = "Legit",
    BHOP_TELEPORT_BOOST = false,
    BHOP_TELEPORT_DISTANCE = 0.5,
    SPINBOT_ENABLED = false,
    SPINBOT_RPM = 600,
    ANTIAIM_ENABLED = false,
    ANTIAIM_YAW_BASE = "Off",
    ANTIAIM_YAW_OFFSET = 0,
    ANTIAIM_SPIN_SPEED = 360,
    ANTIAIM_JITTER_OFFSET = 30,
    ANTIAIM_PITCH = 60,
    THIRDPERSON_ENABLED = false,
    THIRDPERSON_DISTANCE = 9,
    THIRDPERSON_HEIGHT = 0,
    THIRDPERSON_GUARD = true,

    -- chams
    CHAMS_ENABLED = false,
    CHAMS_THROUGH_WALLS = true,
    CHAMS_MODE = "Both",
    CHAMS_STYLE = "Solid",
    CHAMS_COLOR = Color3.fromRGB(255, 60, 60),
    CHAMS_COLOR_SECONDARY = Color3.fromRGB(60, 200, 255),
    CHAMS_FILL_TRANSPARENCY = 0.5,
    CHAMS_OUTLINE_TRANSPARENCY = 0.8,
    CHAMS_PULSE_SPEED = 3,
    CHAMS_GRADIENT_SPEED = 2,
    CHAMS_DISTANCE_NEAR = 100,
    CHAMS_DISTANCE_FAR = 1500,

    -- instant reload
    INSTANT_RELOAD = false,

    -- world
    CAMERA_FOV_ENABLED = false,
    CAMERA_FOV_VALUE = 90,
    CLOCK_TIME_ENABLED = false,
    CLOCK_TIME = 14,
    BRIGHTNESS_ENABLED = false,
    BRIGHTNESS = 2,
    AMBIENT_ENABLED = false,
    AMBIENT_COLOR = Color3.fromRGB(100, 100, 100),
    OUTDOOR_AMBIENT_ENABLED = false,
    OUTDOOR_AMBIENT_COLOR = Color3.fromRGB(100, 100, 100),
    FULLBRIGHT = false,
    NO_FOG = false,
    NO_TEXTURES = false,
    REMOVE_GRASS = false,
    SKYBOX_ENABLED = false,
    SKYBOX_ID = "rbxassetid://159454299",
    MAP_COLOR_ENABLED = false,
    MAP_COLOR_MODE = "Tint",
    MAP_COLOR = Color3.fromRGB(255, 255, 255),
    MAP_SATURATION = 0,
    BLOOM_ENABLED = false,
    BLOOM_INTENSITY = 1,
    BLOOM_SIZE = 24,
    BLOOM_THRESHOLD = 0.9,
    COLOR_CORRECTION_ENABLED = false,
    CC_BRIGHTNESS = 0,
    CC_CONTRAST = 0,
    CC_SATURATION = 0,
    CC_TINT_COLOR = Color3.fromRGB(255, 255, 255),
    SUN_RAYS_ENABLED = false,
    SUN_RAYS_INTENSITY = 0.25,
    SUN_RAYS_SPREAD = 1,
    MOTION_BLUR_ENABLED = false,
    MOTION_BLUR_STRENGTH = 1,


    -- utilities
    ANTI_FLASH_ENABLED = true,
    ANTI_FLASH_TRANSPARENCY = 0.27,

    -- weapons
    NO_RECOIL = false,
    NO_SPREAD = false,
    CUSTOM_RPM_ENABLED = false,
    CUSTOM_RPM_VALUE = 1018,
    FORCE_FULL_AUTO = false,

    -- bullet tracer
    BULLET_TRACER_ENABLED = false,
    BULLET_TRACER_COLOR = Color3.fromRGB(186, 140, 255),
    BULLET_TRACER_THICKNESS = 1.5,
    BULLET_TRACER_DURATION = 0.6,

    -- skins
    AUTO_LAUNCH_SKINCHANGER = false,
    SKINS_ENABLED = true,
    KNIFE_SKINS_ENABLED = true,
    WEAPON_SKINS_ENABLED = true,
    KNIFE_MODEL = "Butterfly Knife",
    KNIFE_SKIN = "Special",
    SELECTED_WEAPON_TYPE = "AK-47",
    SELECTED_SKINS = {},
    SKIN_MODE = "Special",
    EQUIP_BUTTERFLY_KNIFE = true,

    -- hit sound
    HITSOUND_ENABLED = false,
    HITSOUND_VOLUME = 70,
    HITSOUND_FILE = "hvh_crystal_hitsound.mp3",
    HITSOUND_ASSET_ID = "",
    -- uploaded Roblox audio ids, keyed by the local file they belong to
    HITSOUND_IDS = {
        ["hvh_crystal_hitsound.mp3"] = "115025250348704",
        ["metal.wav"] = "140203855957422",
        ["minecraft_bow_hit"] = "135478009117226",
        ["tf2_critical"] = "137392628136734",
        ["undertale_critical"] = "140181868959125"
    },

    -- keybinds
    TOGGLE_UI_KEY = Enum.KeyCode.Insert,
    TOGGLE_UI_KEY_ALT = Enum.KeyCode.RightShift,
    TOGGLE_AIM_KEY = nil,
    AIM_BIND_MODE = "Toggle",
    TOGGLE_ESP_KEY = nil,
    UNLOAD_KEY = Enum.KeyCode.P,

    -- ui state
    MENU_OPEN = true,
    WINDOW_SIZE_X = 442,
    WINDOW_SIZE_Y = 292,

    -- visual colors
    CT_COLOR = Color3.fromRGB(0, 160, 255),
    CT_OUTLINE = Color3.fromRGB(150, 220, 255),
    T_COLOR = Color3.fromRGB(255, 140, 0),
    T_OUTLINE = Color3.fromRGB(255, 220, 100),
    TARGET_COLOR = Color3.fromRGB(0, 255, 0),
    TARGET_OUTLINE = Color3.fromRGB(0, 200, 0),

    -- theme (lavender)
    UI_THEME = {
        FontColor       = Color3.fromRGB(250, 250, 250),
        MainColor       = Color3.fromRGB(30, 26, 42),
        BackgroundColor = Color3.fromRGB(21, 18, 32),
        AccentColor     = Color3.fromRGB(186, 140, 255),
        OutlineColor    = Color3.fromRGB(58, 50, 76),
        RiskColor       = Color3.fromRGB(255, 60, 60)
    },

    -- runtime target state
    CurrentTargetChar = nil,
    CurrentTargetPart = nil,
    LockedTargetChar = nil,
    WaitingForM1Release = false
}

-- defaults
local DEFAULT_VALUES = {
    SILENT_AIM_ENABLED = true,
    KEEP_TARGET_LOCK = true,
    FOV_DEG = 13,
    FOV_CIRCLE_ENABLED = true,
    FOV_CIRCLE_TRANSPARENCY = 0.34,
    BODYPART_TARGET_HL = true,
    TARGET_PRIORITY = "Auto",
    AIM_OCCLUSION_CHECK = false,
    WALLBANG_ENABLED = false,
    HIT_CHANCE_ENABLED = false,
    HIT_CHANCE = 100,
    ESP_ENABLED = true,
    SKELETON_ENABLED = true,
    NAME_ESP_ENABLED = true,
    ITEM_ESP_ENABLED = true,
    BOX_ESP_ENABLED = true,
    BOX_ESP_CORNERS_ONLY = true,
    C4_ESP_ENABLED = false,
    VIEWANGLE_ENABLED = true,
    OFFSCREEN_ARROWS = true,
    DISABLE_TEAMMATES = true,
    OCCLUSION_CHECK_ENABLED = true,
    SPECTATE_CHECKER_ENABLED = true,
    BHOP_ENABLED = true,
    BHOP_AUTO_JUMP = true,
    BHOP_AUTO_STRAFE = true,
    BHOP_STRAFE_FORCE = 2,
    BHOP_MIN_SPEED = 10,
    BHOP_MODE = "Legit",
    BHOP_TELEPORT_BOOST = false,
    BHOP_TELEPORT_DISTANCE = 0.5,
    ANTI_FLASH_ENABLED = true,
    ANTI_FLASH_TRANSPARENCY = 0.27,
    NO_RECOIL = false,
    NO_SPREAD = false,
    CUSTOM_RPM_ENABLED = false,
    CUSTOM_RPM_VALUE = 1018,
    FORCE_FULL_AUTO = false,
    BULLET_TRACER_ENABLED = false,
    BULLET_TRACER_THICKNESS = 1.5,
    BULLET_TRACER_DURATION = 0.6,
    AUTO_LAUNCH_SKINCHANGER = false,
    SKINS_ENABLED = true,
    KNIFE_SKINS_ENABLED = true,
    WEAPON_SKINS_ENABLED = true,
    KNIFE_MODEL = "Butterfly Knife",
    KNIFE_SKIN = "Special",
    SELECTED_WEAPON_TYPE = "AK-47",
    SELECTED_SKINS = {},
    SKIN_MODE = "Special",
    EQUIP_BUTTERFLY_KNIFE = true,
    HITSOUND_ENABLED = false,
    HITSOUND_VOLUME = 70,
    HITSOUND_FILE = "hvh_crystal_hitsound.mp3",
    HITSOUND_ASSET_ID = "",
    HITSOUND_IDS = {
        ["hvh_crystal_hitsound.mp3"] = "115025250348704",
        ["metal.wav"] = "140203855957422",
        ["minecraft_bow_hit"] = "135478009117226",
        ["tf2_critical"] = "137392628136734",
        ["undertale_critical"] = "140181868959125"
    },
    SPINBOT_ENABLED = false,
    SPINBOT_RPM = 600,
    ANTIAIM_ENABLED = false,
    ANTIAIM_YAW_BASE = "Off",
    ANTIAIM_YAW_OFFSET = 0,
    ANTIAIM_SPIN_SPEED = 360,
    ANTIAIM_JITTER_OFFSET = 30,
    ANTIAIM_PITCH = 60,
    THIRDPERSON_ENABLED = false,
    THIRDPERSON_DISTANCE = 9,
    THIRDPERSON_HEIGHT = 0,
    THIRDPERSON_GUARD = true,

    -- chams
    CHAMS_ENABLED = false,
    CHAMS_THROUGH_WALLS = true,
    CHAMS_MODE = "Both",
    CHAMS_STYLE = "Solid",
    CHAMS_COLOR = Color3.fromRGB(255, 60, 60),
    CHAMS_COLOR_SECONDARY = Color3.fromRGB(60, 200, 255),
    CHAMS_FILL_TRANSPARENCY = 0.5,
    CHAMS_OUTLINE_TRANSPARENCY = 0.8,
    CHAMS_PULSE_SPEED = 3,
    CHAMS_GRADIENT_SPEED = 2,
    CHAMS_DISTANCE_NEAR = 100,
    CHAMS_DISTANCE_FAR = 1500,

    -- instant reload
    INSTANT_RELOAD = false,

    -- world
    CAMERA_FOV_ENABLED = false,
    CAMERA_FOV_VALUE = 90,
    CLOCK_TIME_ENABLED = false,
    CLOCK_TIME = 14,
    BRIGHTNESS_ENABLED = false,
    BRIGHTNESS = 2,
    AMBIENT_ENABLED = false,
    AMBIENT_COLOR = Color3.fromRGB(100, 100, 100),
    OUTDOOR_AMBIENT_ENABLED = false,
    OUTDOOR_AMBIENT_COLOR = Color3.fromRGB(100, 100, 100),
    FULLBRIGHT = false,
    NO_FOG = false,
    NO_TEXTURES = false,
    REMOVE_GRASS = false,
    SKYBOX_ENABLED = false,
    SKYBOX_ID = "rbxassetid://159454299",
    MAP_COLOR_ENABLED = false,
    MAP_COLOR_MODE = "Tint",
    MAP_COLOR = Color3.fromRGB(255, 255, 255),
    MAP_SATURATION = 0,
    BLOOM_ENABLED = false,
    BLOOM_INTENSITY = 1,
    BLOOM_SIZE = 24,
    BLOOM_THRESHOLD = 0.9,
    COLOR_CORRECTION_ENABLED = false,
    CC_BRIGHTNESS = 0,
    CC_CONTRAST = 0,
    CC_SATURATION = 0,
    CC_TINT_COLOR = Color3.fromRGB(255, 255, 255),
    SUN_RAYS_ENABLED = false,
    SUN_RAYS_INTENSITY = 0.25,
    SUN_RAYS_SPREAD = 1,
    MOTION_BLUR_ENABLED = false,
    MOTION_BLUR_STRENGTH = 1,

    WINDOW_SIZE_X = 442,
    WINDOW_SIZE_Y = 292,
    TOGGLE_UI_KEY = "Insert",
    TOGGLE_UI_KEY_ALT = "RightShift",
    TOGGLE_AIM_KEY = "None",
    AIM_BIND_MODE = "Toggle",
    TOGGLE_ESP_KEY = "None",
    UNLOAD_KEY = "P"
}

Config._keysDown = {}

if not _G.__bloxstrikeInputTracked then
    _G.__bloxstrikeInputTracked = true
    UserInputService.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Keyboard then
            Config._keysDown[input.KeyCode] = true
            Config._keysDown[input.KeyCode.Name] = true
        elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
            Config._keysDown["MB1"] = true
        elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
            Config._keysDown["MB2"] = true
        elseif input.UserInputType == Enum.UserInputType.MouseButton3 then
            Config._keysDown["MB3"] = true
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Keyboard then
            Config._keysDown[input.KeyCode] = false
            Config._keysDown[input.KeyCode.Name] = false
        elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
            Config._keysDown["MB1"] = false
        elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
            Config._keysDown["MB2"] = false
        elseif input.UserInputType == Enum.UserInputType.MouseButton3 then
            Config._keysDown["MB3"] = false
        end
    end)
end

local InputController = nil
pcall(function()
    InputController = require(game:GetService("ReplicatedStorage").Controllers.InputController)
end)

-- MB1/MB2/MB3 are UserInputType values, looking them up in Enum.KeyCode throws
local MOUSE_KEYS = { MB1 = true, MB2 = true, MB3 = true }

local function safeKeyCode(name)
    if type(name) ~= "string" then return nil end
    if MOUSE_KEYS[name] then return nil end

    local ok, keyCode = pcall(function() return Enum.KeyCode[name] end)
    if ok and keyCode then return keyCode end

    return nil
end

-- aim key held check
function Config.isAimKeyHeld()
    local key = Config.TOGGLE_AIM_KEY
    if not key or key == "None" or key == "" then
        return true
    end

    -- 1. Check mouse buttons
    if key == "MB1" or key == Enum.UserInputType.MouseButton1 then
        if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) or (Config._keysDown["MB1"] == true) then
            return true
        end
    elseif key == "MB2" or key == Enum.UserInputType.MouseButton2 then
        if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) or (Config._keysDown["MB2"] == true) then
            return true
        end
    elseif key == "MB3" or key == Enum.UserInputType.MouseButton3 then
        if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton3) or (Config._keysDown["MB3"] == true) then
            return true
        end
    end

    -- keycode
    if typeof(key) == "EnumItem" and key.EnumType == Enum.KeyCode then
        if UserInputService:IsKeyDown(key) or (Config._keysDown[key] == true) or (Config._keysDown[key.Name] == true) then
            return true
        end
    end

    -- string key name
    if type(key) == "string" then
        local kc = safeKeyCode(key)
        if kc and UserInputService:IsKeyDown(kc) then
            return true
        end
        if (Config._keysDown[key] == true) or (kc and Config._keysDown[kc] == true) then
            return true
        end
    end

    -- InputController actions
    if InputController then
        local targetKc = (typeof(key) == "EnumItem" and key.EnumType == Enum.KeyCode) and key or safeKeyCode(key)
        if targetKc then
            local okBind, isPressed = pcall(InputController.isBindingPressed, targetKc)
            if okBind and isPressed == true then
                return true
            end
        end

        local okUps, upsList = pcall(function()
            if debug and debug.getupvalues then
                return debug.getupvalues(InputController.isActionActive)
            end
            return nil
        end)
        if okUps and type(upsList) == "table" and type(upsList[1]) == "table" then
            for _, act in pairs(upsList[1]) do
                if type(act) == "table" and act.IsActive == true and type(act.Keybinds) == "table" then
                    for _, kb in ipairs(act.Keybinds) do
                        if kb == key or (targetKc and kb == targetKc) or (typeof(kb) == "EnumItem" and kb.Name == key) then
                            return true
                        end
                    end
                end
            end
        end
    end

    return false
end

-- silent aim active check
function Config.isSilentAimActive()
    if UserInputService:GetFocusedTextBox() then
        return false
    end

    local key = Config.TOGGLE_AIM_KEY
    local hasKey = key and key ~= "None" and key ~= ""

    local mode = Config.AIM_BIND_MODE or "Toggle"
    if hasKey and mode == "Hold" then
        return Config.isAimKeyHeld()
    end

    return (Config.SILENT_AIM_ENABLED ~= false)
end

-- save settings
function Config.save()
    if type(writefile) ~= "function" then return false, "writefile not available" end

    local payload = {
        SILENT_AIM_ENABLED = Config.SILENT_AIM_ENABLED,
        KEEP_TARGET_LOCK = Config.KEEP_TARGET_LOCK,
        FOV_DEG = Config.FOV_DEG or 30,
        FOV_CIRCLE_ENABLED = Config.FOV_CIRCLE_ENABLED,
        FOV_CIRCLE_TRANSPARENCY = Config.FOV_CIRCLE_TRANSPARENCY,
        BODYPART_TARGET_HL = Config.BODYPART_TARGET_HL,
        TARGET_PRIORITY = Config.TARGET_PRIORITY or "Auto",
        AIM_OCCLUSION_CHECK = (Config.AIM_OCCLUSION_CHECK == true),
        WALLBANG_ENABLED = Config.WALLBANG_ENABLED,
        HIT_CHANCE_ENABLED = (Config.HIT_CHANCE_ENABLED == true),
        HIT_CHANCE = Config.HIT_CHANCE or 100,
        HITSOUND_ENABLED = (Config.HITSOUND_ENABLED == true),
        HITSOUND_VOLUME = Config.HITSOUND_VOLUME or 70,
        HITSOUND_FILE = Config.HITSOUND_FILE or "hvh_crystal_hitsound.mp3",
        HITSOUND_ASSET_ID = Config.HITSOUND_ASSET_ID or "",
        HITSOUND_IDS = Config.HITSOUND_IDS or {},

        ESP_ENABLED = Config.ESP_ENABLED,
        SKELETON_ENABLED = Config.SKELETON_ENABLED,
        NAME_ESP_ENABLED = (Config.NAME_ESP_ENABLED ~= false),
        ITEM_ESP_ENABLED = (Config.ITEM_ESP_ENABLED ~= false),
        BOX_ESP_ENABLED = (Config.BOX_ESP_ENABLED ~= false),
        BOX_ESP_CORNERS_ONLY = (Config.BOX_ESP_CORNERS_ONLY ~= false),
        C4_ESP_ENABLED = (Config.C4_ESP_ENABLED == true),
        VIEWANGLE_ENABLED = Config.VIEWANGLE_ENABLED,
        OFFSCREEN_ARROWS = Config.OFFSCREEN_ARROWS,
        DISABLE_TEAMMATES = Config.DISABLE_TEAMMATES,
        OCCLUSION_CHECK_ENABLED = Config.OCCLUSION_CHECK_ENABLED,
        SPECTATE_CHECKER_ENABLED = Config.SPECTATE_CHECKER_ENABLED,

        BHOP_ENABLED = Config.BHOP_ENABLED,
        BHOP_AUTO_JUMP = (Config.BHOP_AUTO_JUMP ~= false),
        BHOP_AUTO_STRAFE = (Config.BHOP_AUTO_STRAFE ~= false),
        BHOP_STRAFE_FORCE = Config.BHOP_STRAFE_FORCE or 2,
        BHOP_MIN_SPEED = Config.BHOP_MIN_SPEED or 10,
        BHOP_MODE = Config.BHOP_MODE or "Legit",
        BHOP_TELEPORT_BOOST = (Config.BHOP_TELEPORT_BOOST == true),
        BHOP_TELEPORT_DISTANCE = Config.BHOP_TELEPORT_DISTANCE or 0.5,

        ANTI_FLASH_ENABLED = Config.ANTI_FLASH_ENABLED,
        ANTI_FLASH_TRANSPARENCY = Config.ANTI_FLASH_TRANSPARENCY,

        NO_RECOIL = (Config.NO_RECOIL == true),
        NO_SPREAD = (Config.NO_SPREAD == true),
        CUSTOM_RPM_ENABLED = Config.CUSTOM_RPM_ENABLED,
        CUSTOM_RPM_VALUE = Config.CUSTOM_RPM_VALUE,
        FORCE_FULL_AUTO = Config.FORCE_FULL_AUTO,
        SPINBOT_ENABLED = (Config.SPINBOT_ENABLED == true),
        SPINBOT_RPM = Config.SPINBOT_RPM or 600,
        ANTIAIM_ENABLED = (Config.ANTIAIM_ENABLED == true),
        ANTIAIM_YAW_BASE = Config.ANTIAIM_YAW_BASE or "Off",
        ANTIAIM_YAW_OFFSET = Config.ANTIAIM_YAW_OFFSET or 0,
        ANTIAIM_SPIN_SPEED = Config.ANTIAIM_SPIN_SPEED or 360,
        ANTIAIM_JITTER_OFFSET = Config.ANTIAIM_JITTER_OFFSET or 30,
        ANTIAIM_PITCH = Config.ANTIAIM_PITCH or 60,
        THIRDPERSON_ENABLED = (Config.THIRDPERSON_ENABLED == true),
        THIRDPERSON_DISTANCE = Config.THIRDPERSON_DISTANCE or 9,
        THIRDPERSON_HEIGHT = Config.THIRDPERSON_HEIGHT or 0,
        THIRDPERSON_GUARD = (Config.THIRDPERSON_GUARD ~= false),
        CAMERA_FOV_ENABLED = (Config.CAMERA_FOV_ENABLED == true),
        CAMERA_FOV_VALUE = Config.CAMERA_FOV_VALUE or 90,
        BULLET_TRACER_ENABLED = (Config.BULLET_TRACER_ENABLED == true),
        BULLET_TRACER_THICKNESS = Config.BULLET_TRACER_THICKNESS or 1.5,
        BULLET_TRACER_DURATION = Config.BULLET_TRACER_DURATION or 0.6,
        AUTO_LAUNCH_SKINCHANGER = (Config.AUTO_LAUNCH_SKINCHANGER == true),

        -- chams
        CHAMS_ENABLED = (Config.CHAMS_ENABLED == true),
        CHAMS_THROUGH_WALLS = (Config.CHAMS_THROUGH_WALLS ~= false),
        CHAMS_MODE = Config.CHAMS_MODE or "Both",
        CHAMS_STYLE = Config.CHAMS_STYLE or "Solid",
        CHAMS_COLOR = Config.CHAMS_COLOR or Color3.fromRGB(255, 60, 60),
        CHAMS_COLOR_SECONDARY = Config.CHAMS_COLOR_SECONDARY or Color3.fromRGB(60, 200, 255),
        CHAMS_FILL_TRANSPARENCY = Config.CHAMS_FILL_TRANSPARENCY or 0.5,
        CHAMS_OUTLINE_TRANSPARENCY = Config.CHAMS_OUTLINE_TRANSPARENCY or 0.8,
        CHAMS_PULSE_SPEED = Config.CHAMS_PULSE_SPEED or 3,
        CHAMS_GRADIENT_SPEED = Config.CHAMS_GRADIENT_SPEED or 2,
        CHAMS_DISTANCE_NEAR = Config.CHAMS_DISTANCE_NEAR or 100,
        CHAMS_DISTANCE_FAR = Config.CHAMS_DISTANCE_FAR or 1500,

        -- instant reload
        INSTANT_RELOAD = (Config.INSTANT_RELOAD == true),

        -- world
        CLOCK_TIME_ENABLED = (Config.CLOCK_TIME_ENABLED == true),
        CLOCK_TIME = Config.CLOCK_TIME or 14,
        BRIGHTNESS_ENABLED = (Config.BRIGHTNESS_ENABLED == true),
        BRIGHTNESS = Config.BRIGHTNESS or 2,
        AMBIENT_ENABLED = (Config.AMBIENT_ENABLED == true),
        AMBIENT_COLOR = Config.AMBIENT_COLOR or Color3.fromRGB(100, 100, 100),
        OUTDOOR_AMBIENT_ENABLED = (Config.OUTDOOR_AMBIENT_ENABLED == true),
        OUTDOOR_AMBIENT_COLOR = Config.OUTDOOR_AMBIENT_COLOR or Color3.fromRGB(100, 100, 100),
        FULLBRIGHT = (Config.FULLBRIGHT == true),
        NO_FOG = (Config.NO_FOG == true),
        NO_TEXTURES = (Config.NO_TEXTURES == true),
        REMOVE_GRASS = (Config.REMOVE_GRASS == true),
        SKYBOX_ENABLED = (Config.SKYBOX_ENABLED == true),
        SKYBOX_ID = Config.SKYBOX_ID or "rbxassetid://159454299",
        MAP_COLOR_ENABLED = (Config.MAP_COLOR_ENABLED == true),
        MAP_COLOR_MODE = Config.MAP_COLOR_MODE or "Tint",
        MAP_COLOR = Config.MAP_COLOR or Color3.fromRGB(255, 255, 255),
        MAP_SATURATION = Config.MAP_SATURATION or 0,
        BLOOM_ENABLED = (Config.BLOOM_ENABLED == true),
        BLOOM_INTENSITY = Config.BLOOM_INTENSITY or 1,
        BLOOM_SIZE = Config.BLOOM_SIZE or 24,
        BLOOM_THRESHOLD = Config.BLOOM_THRESHOLD or 0.9,
        COLOR_CORRECTION_ENABLED = (Config.COLOR_CORRECTION_ENABLED == true),
        CC_BRIGHTNESS = Config.CC_BRIGHTNESS or 0,
        CC_CONTRAST = Config.CC_CONTRAST or 0,
        CC_SATURATION = Config.CC_SATURATION or 0,
        CC_TINT_COLOR = Config.CC_TINT_COLOR or Color3.fromRGB(255, 255, 255),
        SUN_RAYS_ENABLED = (Config.SUN_RAYS_ENABLED == true),
        SUN_RAYS_INTENSITY = Config.SUN_RAYS_INTENSITY or 0.25,
        SUN_RAYS_SPREAD = Config.SUN_RAYS_SPREAD or 1,
        MOTION_BLUR_ENABLED = (Config.MOTION_BLUR_ENABLED == true),
        MOTION_BLUR_STRENGTH = Config.MOTION_BLUR_STRENGTH or 1,

        SKINS_ENABLED = Config.SKINS_ENABLED,
        KNIFE_SKINS_ENABLED = Config.KNIFE_SKINS_ENABLED,
        WEAPON_SKINS_ENABLED = Config.WEAPON_SKINS_ENABLED,
        KNIFE_MODEL = Config.KNIFE_MODEL or "Butterfly Knife",
        KNIFE_SKIN = Config.KNIFE_SKIN or "Special",
        SELECTED_WEAPON_TYPE = Config.SELECTED_WEAPON_TYPE or "AK-47",
        SELECTED_SKINS = Config.SELECTED_SKINS or {},
        SKIN_MODE = Config.SKIN_MODE or "Special",
        EQUIP_BUTTERFLY_KNIFE = Config.EQUIP_BUTTERFLY_KNIFE,

        WINDOW_SIZE_X = Config.WINDOW_SIZE_X or 440,
        WINDOW_SIZE_Y = Config.WINDOW_SIZE_Y or 210,

        TOGGLE_UI_KEY = Config.TOGGLE_UI_KEY and Config.TOGGLE_UI_KEY.Name or "None",
        TOGGLE_UI_KEY_ALT = Config.TOGGLE_UI_KEY_ALT and Config.TOGGLE_UI_KEY_ALT.Name or "None",
        TOGGLE_AIM_KEY = (type(Config.TOGGLE_AIM_KEY) == "string" and Config.TOGGLE_AIM_KEY) or (Config.TOGGLE_AIM_KEY and Config.TOGGLE_AIM_KEY.Name) or "None",
        AIM_BIND_MODE = Config.AIM_BIND_MODE or "Toggle",
        TOGGLE_ESP_KEY = Config.TOGGLE_ESP_KEY and Config.TOGGLE_ESP_KEY.Name or "None",
        UNLOAD_KEY = Config.UNLOAD_KEY and Config.UNLOAD_KEY.Name or "None"
    }

    ensureDirectory()
    local ok, encoded = pcall(function() return HttpService:JSONEncode(payload) end)
    if ok and encoded then
        local writeOk, err = pcall(writefile, CONFIG_FILE, encoded)
        if writeOk then
            return true
        end
    end
    return false
end

-- load settings
function Config.load()
    if type(readfile) ~= "function" then return false end

    local exists = false
    if type(isfile) == "function" then
        exists = isfile(CONFIG_FILE)
    else
        local testOk, testData = pcall(readfile, CONFIG_FILE)
        exists = testOk and (testData ~= nil and #testData > 0)
    end

    if not exists then return false end

    local ok, raw = pcall(readfile, CONFIG_FILE)
    if not ok or not raw or #raw == 0 then return false end

    local decodeOk, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not decodeOk or type(data) ~= "table" then return false end

    for key, val in pairs(data) do
        if key == "TOGGLE_AIM_KEY" then
            if val == "None" or val == nil or val == "" then
                Config[key] = nil
            elseif val == "MB1" or val == "MB2" or val == "MB3" then
                Config[key] = val
            else
                local kc = Enum.KeyCode[val]
                Config[key] = kc or nil
            end
        elseif key == "TOGGLE_UI_KEY" or key == "TOGGLE_UI_KEY_ALT" or key == "TOGGLE_ESP_KEY" or key == "UNLOAD_KEY" then
            if val == "None" or val == nil or val == "" then
                Config[key] = nil
            else
                local kc = Enum.KeyCode[val]
                Config[key] = kc or nil
            end
        elseif key == "AIM_BIND_MODE" then
            Config.AIM_BIND_MODE = (val == "Hold") and "Hold" or "Toggle"
        elseif key == "AUTO_LAUNCH_SKINCHANGER" then
            Config.AUTO_LAUNCH_SKINCHANGER = (val == true)
        elseif key == "KNIFE_SKINS_ENABLED" then
            Config.KNIFE_SKINS_ENABLED = (val == true)
        elseif key == "WEAPON_SKINS_ENABLED" then
            Config.WEAPON_SKINS_ENABLED = (val == true)
        elseif key == "SELECTED_WEAPON_TYPE" then
            Config.SELECTED_WEAPON_TYPE = tostring(val)
        elseif key == "SELECTED_SKINS" and type(val) == "table" then
            Config.SELECTED_SKINS = val
        elseif key == "KNIFE_MODEL" then
            Config.KNIFE_MODEL = tostring(val)
        elseif key == "KNIFE_SKIN" then
            Config.KNIFE_SKIN = tostring(val)
        elseif key == "SKIN_MODE" then
            local str = tostring(val)
            Config.SKIN_MODE = (str == "Random") and "Random" or "Special"
        elseif key == "FOV_DEG" then
            Config.FOV_DEG = tonumber(val) or 30
        elseif key == "FOV_RADIUS" and not data.FOV_DEG then
            local num = tonumber(val) or 30
            Config.FOV_DEG = (num > 180) and 30 or num
        elseif key == "WINDOW_SIZE_X" or key == "WINDOW_SIZE_Y" then
            local num = tonumber(val)
            if num and num > 0 then Config[key] = num end
        elseif Config[key] ~= nil and type(Config[key]) == type(val) then
            Config[key] = val
        end
    end

    return true
end

-- reset defaults
function Config.reset()
    for key, val in pairs(DEFAULT_VALUES) do
        if key == "TOGGLE_UI_KEY" or key == "TOGGLE_UI_KEY_ALT" or key == "TOGGLE_AIM_KEY" or key == "UNLOAD_KEY" then
            local kc = Enum.KeyCode[val]
            if kc then Config[key] = kc else Config[key] = (val == "None" and nil or val) end
        else
            Config[key] = val
        end
    end
    Config.save()
end

return Config