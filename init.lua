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

local BRANCH_MAIN = (_G.BloxstrikeBranch or "main")

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

-- Load the arvn UI library. Without it there is no menu, so it must be available
-- before anything that touches Config or UIManager.
--
-- The pcall results must be captured in order: okArvn is the success flag and
-- arvnResult is the returned library table. Discarding the first return value
-- here made every load look like a failure.
local Arvn = nil
do
    local okArvn, arvnResult = pcall(function()
        local src = game:HttpGet("https://raw.githubusercontent.com/koteqjjjj/arvn/main/arvn.lua")
        local chunk = loadstring(src)
        if not chunk then error("loadstring returned nil") end
        return chunk()
    end)

    if okArvn and type(arvnResult) == "table" then
        Arvn = arvnResult
    else
        error("[Bloxstrike] Failed to load the arvn UI library: "
            .. tostring(arvnResult))
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


    _G.__bloxstrikeJanitor = nil
    _G.__bloxstrikeConfig = nil
end

_G.__bloxstrikeJanitor = cleanup
_G.__bloxstrikeConfig = Config


-- init ui (the main cheat's arvn window)
reportInit("UIManager", function()
    UIManager.init(Config, Arvn, WeaponEngine, cleanup, HitSound)
end)

-- ==========================================================
-- Frame profiler
-- ==========================================================
--
-- The C4 pickup hitch has now survived two fixes that were both made by reading the
-- code, and both were aimed at tree walks that measurement shows are cheap. So
-- nothing else gets changed until the time is actually attributed.
--
-- The distinction that matters is not "which module is slow" but "are WE slow at
-- all". A frame can take 80ms while every module in this cheat totals 3ms, and that
-- is the game replicating the bomb model - a different problem with a different fix,
-- and one that no amount of walk-throttling would help. So the frame delta is
-- recorded alongside the sum of our own work; when the two diverge, the hitch is not
-- ours and further "optimising" the cheat is the wrong move.
--
-- max is reported rather than average. A hitch is one bad frame, and a module that
-- is free for 59 frames and costs 40ms once averages to nothing.
local perf = { buckets = {}, frameMax = 0, frameSum = 0, frameN = 0, oursMax = 0 }

local function timed(name, fn, ...)
    local started = os.clock()
    local a, b, c = fn(...)
    local dt = os.clock() - started
    local e = perf.buckets[name]
    if not e then e = { t = 0, n = 0, max = 0 }; perf.buckets[name] = e end
    e.t = e.t + dt
    e.n = e.n + 1
    if dt > e.max then e.max = dt end
    return a, b, c
end

local function fmtMs(s) return string.format("%.1f", s * 1000) end

-- C4ESP runs from its own RenderStepped connection, not from the loop below, so it
-- needs the profiler exposed rather than wrapped at the call site.
_G.__bloxstrikeTimed = timed

local perfReportAt = -999
local perfConnection = nil

local function reportPerf(forceFrame)
    local names = {}
    for name in pairs(perf.buckets) do names[#names + 1] = name end
    table.sort(names)

    local parts = {}
    local oursMax = 0
    for _, name in ipairs(names) do
        local e = perf.buckets[name]
        if e.max > oursMax then oursMax = e.max end
        parts[#parts + 1] = string.format("%s max=%s", name, fmtMs(e.max))
    end

    local frameAvg = 0
    if perf.frameN > 0 then frameAvg = perf.frameSum / perf.frameN end

    local line = string.format(
        "PERF frame max=%s avg=%s | ours max=%s | %s",
        fmtMs(perf.frameMax), fmtMs(frameAvg), fmtMs(oursMax),
        table.concat(parts, "  "))

    local c4 = nil
    pcall(function() c4 = C4ESP.TakeStats() end)
    if c4 and #c4 > 0 then line = line .. " || C4: " .. c4 end

    pcall(warn, "[Bloxstrike] " .. line)

    if forceFrame and perf.frameMax > (oursMax * 2) and perf.frameMax > 0.02 then
        -- The gap between the frame and our own work is the useful number: it says
        -- how much of the hitch this cheat is even responsible for.
        pcall(warn, string.format(
            "[Bloxstrike] frame %.1fms vs ours %.1fms -> %.0f%% is NOT us",
            perf.frameMax * 1000, oursMax * 1000,
            (1 - (oursMax / math.max(perf.frameMax, 1e-6))) * 100))
    end

    perf.buckets = {}
    perf.frameMax = 0
    perf.frameSum = 0
    perf.frameN = 0
end

-- render loop
renderConn = RunService.RenderStepped:Connect(function(dt)
    perf.frameMax = math.max(perf.frameMax, dt)
    perf.frameSum = perf.frameSum + dt
    perf.frameN = perf.frameN + 1

    local now = os.clock()
    if (now - perfReportAt) >= 1.0 then
        perfReportAt = now
        -- Reported off the render path is impossible, so this is a deferred call:
        -- doing the formatting inline would charge our own reporting to the very
        -- frame being measured.
        task.defer(reportPerf)
    end

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

    timed("TargetEngine", TargetEngine.update, Config, Utils, DamageEngine)
    timed("ESPManager", ESPManager.update, Config, Utils, SkeletonRenderer)
    timed("SpectateChecker", SpectateChecker.update, Config)
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
