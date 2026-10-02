-- @Discord_alvin6974. / Bloxstrike / v2.5
-- Repository: https://github.com/alvin12127/roblox_bloxstrike_main
-- NOTE: raw URL은 본인 저장소 기준으로 완전 교체됨 (원본 fallback 없음)

-- cleanup existing instances
if _G.__agScriptJanitor then pcall(_G.__agScriptJanitor) _G.__agScriptJanitor = nil end
if _G.__bloxstrikeJanitor then pcall(_G.__bloxstrikeJanitor) _G.__bloxstrikeJanitor = nil end
if _G.__shotAdvisorJanitor then pcall(_G.__shotAdvisorJanitor) _G.__shotAdvisorJanitor = nil end
if _G.__spectatorUIJanitor then pcall(_G.__spectatorUIJanitor) _G.__spectatorUIJanitor = nil end
if _G.__standaloneRCS then pcall(_G.__standaloneRCS) _G.__standaloneRCS = nil end
if _G.__passiveSuiteJanitor then pcall(_G.__passiveSuiteJanitor) _G.__passiveSuiteJanitor = nil end
if _G.__antiFlashJanitor then pcall(_G.__antiFlashJanitor) _G.__antiFlashJanitor = nil end
if _G.__bhopJanitor then pcall(_G.__bhopJanitor) _G.__bhopJanitor = nil end
if _G.__skinChangerJanitor then pcall(_G.__skinChangerJanitor) _G.__skinChangerJanitor = nil end

if _G.__originalPerformRaycast then
    local ok, b = pcall(function() return require(game:GetService("ReplicatedStorage").Components.Weapon.Classes.Bullet) end)
    if ok and b and _G.__originalPerformRaycast then
        b._performRaycast = _G.__originalPerformRaycast
    end
    _G.__originalPerformRaycast = nil
end

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Camera = Workspace.CurrentCamera

-- Repo + branch to pull modules from.
--
-- The branch is read from a global so a test loader can point the whole cheat at
-- a side branch without this file needing a different version per branch. The
-- URL is built from a table lookup rather than by rewriting game.HttpGet, because
-- executors do not allow assigning to game members.
local REPO_MAIN = "alvin12127/roblox_bloxstrike_main"
local REPO_SC   = "alvin12127/roblox_bloxstrike_SC"

local BRANCH_MAIN = (_G.BloxstrikeBranch or "main")
local BRANCH_SC   = (_G.BloxstrikeSCBranch or "main")

local function rawUrl(repo, branch, path)
    return "https://raw.githubusercontent.com/" .. repo .. "/" .. branch .. "/" .. path
end

-- module loader
local modules = {}
local function import(moduleName)
    if modules[moduleName] then return modules[moduleName] end
    
    -- Run a chunk and return its result, or nil if it fails. A module that
    -- throws must not abort the whole loader.
    local function tryRun(fn)
        if type(fn) ~= "function" then return nil end
        local ok, res = pcall(fn)
        if ok and res then return res end
        return nil
    end

    if type(readfile) == "function" then
        local paths = {
            "roblox_bloxstrike_main/src/" .. moduleName .. ".lua",
            "Bloxstrike/src/" .. moduleName .. ".lua",
            "src/" .. moduleName .. ".lua",
            moduleName .. ".lua"
        }
        for _, path in ipairs(paths) do
            local ok, content = pcall(readfile, path)
            if ok and content and #content > 0 then
                local res = tryRun(loadstring(content))
                if res then
                    modules[moduleName] = res
                    return res
                end
            end
        end
    end

    if _G.__BloxstrikeModules and _G.__BloxstrikeModules[moduleName] then
        local res = tryRun(_G.__BloxstrikeModules[moduleName])
        if res then
            modules[moduleName] = res
            return res
        end
    end

    -- remote github fallback (timestamped so the executor never serves a stale copy)
    local okHttp, remoteContent = pcall(function()
        return game:HttpGet(rawUrl(REPO_MAIN, BRANCH_MAIN,
            "src/" .. moduleName .. ".lua") .. "?t=" .. tostring(os.time()))
    end)
    if okHttp and remoteContent and #remoteContent > 0 then
        local res = tryRun(loadstring(remoteContent))
        if res then
            modules[moduleName] = res
            return res
        end
    end

    error("[Bloxstrike] Failed to import module: " .. tostring(moduleName))
end

-- imports
local Config           = import("Config")
local Utils            = import("Utils")
local DamageEngine     = import("DamageEngine")
local SkeletonRenderer = import("SkeletonRenderer")
local TargetEngine     = import("TargetEngine")
local ESPManager       = import("ESPManager")
local SilentAim        = import("SilentAim")
local Wallbang         = import("Wallbang")
local SpectateChecker  = import("SpectateChecker")
local Bhop             = import("Bhop")
local AntiFlash        = import("AntiFlash")
local WeaponEngine     = import("WeaponEngine")
local HitSound         = import("HitSound")
local BulletTracer     = import("BulletTracer")
local C4ESP           = import("C4ESP")
local GrenadeESP      = import("GrenadeESP")
local SpinBot          = import("SpinBot")
local ThirdPerson      = import("ThirdPerson")
local WorldMods        = import("WorldMods")
local Chams            = import("Chams")
local InstantReload    = import("InstantReload")
local UIManager        = import("UIManager")

-- Load arvn UI library
-- arvn UI library. Without it there is no menu, so load it before anything
-- that expects Config/UIManager to be usable.
local Arvn = nil
do
    local okArvn, arvnErr = pcall(function()
        local src = game:HttpGet("https://raw.githubusercontent.com/koteqjjjj/arvn/main/arvn.lua")
        local chunk = loadstring(src)
        if not chunk then error("loadstring returned nil") end
        return chunk()
    end)
    Arvn = (okArvn and type(Arvn) == "table") and Arvn or nil
    if not Arvn then
        error("[Bloxstrike] Failed to load the arvn UI library: " .. tostring(arvnErr))
    end
end

-- load config
Config.load()

-- setup primitives
ESPManager.init(Config, Utils, SkeletonRenderer)
SpectateChecker.init(Config)
TargetEngine.init(Config)

-- fov circle
local fovCircle = Drawing.new("Circle")
fovCircle.Thickness = 1.5
fovCircle.NumSides = 64
fovCircle.Radius = 100
fovCircle.Filled = false
fovCircle.Transparency = Config.FOV_CIRCLE_TRANSPARENCY or 0.5
fovCircle.Color = Config.FOV_CIRCLE_COLOR or Color3.fromRGB(255, 255, 255)
fovCircle.ZIndex = 1
fovCircle.Visible = Config.FOV_CIRCLE_ENABLED

-- init subsystems
-- Each init is isolated so one failure cannot abort the whole load. Anything that
-- throws is reported by name, so the problem is findable instead of guessable.

local function reportInit(name, func)
    local ok, err = pcall(func)

    if not ok then
        pcall(warn, "[Bloxstrike] init failed [" .. name .. "]: " .. tostring(err))
    end

    return ok
end

reportInit("C4ESP", function() C4ESP.init(Config) end)
reportInit("GrenadeESP", function() GrenadeESP.init(Config) end)
reportInit("SpinBot", function() SpinBot.init(Config) end)
reportInit("ThirdPerson", function() ThirdPerson.init(Config) end)
reportInit("WorldMods", function() WorldMods.init(Config) end)
reportInit("BulletTracer", function() BulletTracer.init(Config) end)
reportInit("HitSound", function() HitSound.init(Config, Utils) end)
reportInit("SilentAim", function() SilentAim.init(Config, Utils, HitSound, BulletTracer) end)
reportInit("Wallbang", function() Wallbang.init(Config) end)
reportInit("Bhop", function() Bhop.init(Config) end)
reportInit("AntiFlash", function() AntiFlash.init(Config) end)
reportInit("WeaponEngine", function() WeaponEngine.init(Config) end)
reportInit("Chams", function() Chams.init(Config, Utils) end)
reportInit("InstantReload", function() InstantReload.init(Config) end)

-- cleanup
local renderConn = nil
local keyConn = nil
local SkinChanger = nil

local function cleanup()
    if renderConn then pcall(function() renderConn:Disconnect() end) end
    if keyConn then pcall(function() keyConn:Disconnect() end) end
    
    UIManager.cleanup()
    WeaponEngine.cleanup()
    WorldMods.cleanup()
    C4ESP.cleanup()
    GrenadeESP.cleanup()
    SpinBot.cleanup()
    ThirdPerson.cleanup()
    BulletTracer.cleanup()
    HitSound.cleanup()
    Bhop.cleanup()
    AntiFlash.cleanup()
    SilentAim.cleanup()
    Wallbang.cleanup()
    TargetEngine.cleanup()
    ESPManager.cleanup(SkeletonRenderer)
    SpectateChecker.cleanup()
    
    pcall(function() fovCircle:Remove() end)

    Chams.cleanup()
    InstantReload.cleanup()

    -- Cleanup skinchanger (catalogs + engine). The catalogs own 3D viewport
    -- RenderStepped connections, so they must be torn down explicitly.
    if SkinChanger then
        for _, key in ipairs({ "KnifeCatalog", "GunCatalog", "GloveCatalog" }) do
            local catalog = SkinChanger[key]
            if catalog and type(catalog.cleanup) == "function" then
                pcall(catalog.cleanup)
            end
        end
        if SkinChanger.API and SkinChanger.API.cleanup then
            pcall(SkinChanger.API.cleanup)
        end
    end
    SkinChanger = nil

    _G.__bloxstrikeJanitor = nil
    _G.__bloxstrikeConfig = nil
end

_G.__bloxstrikeJanitor = cleanup
_G.__bloxstrikeConfig = Config

-- Load the skinchanger engine + catalogs FIRST so the main UI can host them.
-- No separate window is created any more: the catalogs are rendered straight
-- into the main cheat's arvn Skins tab (see UIManager).
reportInit("SkinChanger", function()
    -- Skinchanger has its own module directory - load from there
    local scModules = {}
    local function scImport(moduleName)
        if scModules[moduleName] then return scModules[moduleName] end

        -- Resolve the skinchanger modules from the roblox_bloxstrike_SC repo.
        -- Local readfile paths cover the common layouts, then GitHub is used as
        -- the fallback so a single pasted loader line still works.
        local localPaths = {
            "roblox_bloxstrike_SC/src/" .. moduleName .. ".lua",
            "Bloxstrike-Skinchanger/src/" .. moduleName .. ".lua",
            "src/" .. moduleName .. ".lua",
            moduleName .. ".lua",
        }

        if type(readfile) == "function" then
            for _, path in ipairs(localPaths) do
                local ok, content = pcall(readfile, path)
                if ok and content and #content > 0 then
                    local fn = loadstring(content)
                    if fn then
                        local okRun, res = pcall(fn)
                        if okRun and res then
                            scModules[moduleName] = res
                            return res
                        end
                    end
                end
            end
        end

        -- Remote GitHub fallback
        local okHttp, remoteContent = pcall(function()
            return game:HttpGet(rawUrl(REPO_SC, BRANCH_SC,
            "src/" .. moduleName .. ".lua") .. "?t=" .. tostring(os.time()))
        end)
        if okHttp and remoteContent and #remoteContent > 0 then
            local fn = loadstring(remoteContent)
            if fn then
                local okRun, res = pcall(fn)
                if okRun and res then
                    scModules[moduleName] = res
                    return res
                end
            end
        end

        error("[Skinchanger] Failed to import: " .. tostring(moduleName))
    end

    local scConfig       = scImport("Config")
    local scDatabase     = scImport("Database")
    local scEngine       = scImport("Engine")
    local scAPI          = scImport("API")
    local scKnifeCatalog = scImport("KnifeCatalog")
    local scGunCatalog   = scImport("GunCatalog")
    local scGloveCatalog = scImport("GloveCatalog")

    scAPI.bind(scConfig, scDatabase, scEngine, scKnifeCatalog, scGunCatalog)
    if scAPI.bindGloveCatalog then
        scAPI.bindGloveCatalog(scGloveCatalog)
    end
    scAPI.init()

    -- Expose everything the main UI needs to render the catalogs.
    -- The catalogs' init is deliberately NOT called here: the main UI owns the
    -- skin tab and calls init itself with a TabFrame living inside the arvn
    -- window. Calling init twice would build two sets of 3D viewports and leak
    -- their RenderStepped connections.
    SkinChanger = {
        API = scAPI,
        Database = scDatabase,
        Config = scConfig,
        Engine = scEngine,
        KnifeCatalog = scKnifeCatalog,
        GunCatalog = scGunCatalog,
        GloveCatalog = scGloveCatalog
    }

    _G.SkinChanger = scAPI
end)

-- init ui (main cheat arvn window - hosts the skin catalogs in its Skins tab)
reportInit("UIManager", function()
    UIManager.init(Config, Arvn, SkinChanger, WeaponEngine, cleanup, HitSound)
end)

-- render loop
renderConn = RunService.RenderStepped:Connect(function(dt)
    local vpCenter = Camera.ViewportSize * 0.5
    fovCircle.Position = Vector2.new(vpCenter.X, vpCenter.Y)

    -- angular fov projection
    local fovDeg = Config.FOV_DEG or 30
    if fovDeg >= 180 then
        fovCircle.Radius = math.max(Camera.ViewportSize.X, Camera.ViewportSize.Y) * 2
    else
        local camFov = math.clamp(Camera.FieldOfView, 1, 120)
        local focalLength = (Camera.ViewportSize.Y * 0.5) / math.tan(math.rad(camFov * 0.5))
        local radiusPx = focalLength * math.tan(math.rad(math.min(fovDeg, 89.5)))
        fovCircle.Radius = radiusPx
    end

    fovCircle.Color = Config.FOV_CIRCLE_COLOR
    fovCircle.Transparency = Config.FOV_CIRCLE_TRANSPARENCY
    fovCircle.Visible = (Config.FOV_CIRCLE_ENABLED ~= false) and (Config.ESP_ENABLED ~= false)

    TargetEngine.update(Config, Utils, DamageEngine)
    ESPManager.update(Config, Utils, SkeletonRenderer)
    SpectateChecker.update(Config)
end)

-- unload key listener
keyConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if UserInputService:GetFocusedTextBox() then return end
    if Arvn and Arvn.IsPickingKey then return end
    if Config.UNLOAD_KEY and input.KeyCode == Config.UNLOAD_KEY then
        cleanup()
    end
end)

-- console marker. If this line is missing from F9 the load aborted before finishing.
pcall(warn, "[Bloxstrike] init complete")
print("@Discord_alvin6974. / Bloxstrike / v2.5")
return "@Discord_alvin6974. / Bloxstrike / v2.5"