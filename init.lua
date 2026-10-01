-- @Discord_alvin6974. / Bloxstrike Skinchanger / Standalone Engine
-- NOTE: raw URL은 본인 저장소 기준으로 완전 교체됨 (원본 fallback 없음)

-- Cleanup previous instance
if _G.__alvinSkinChangerJanitor then
    pcall(_G.__alvinSkinChangerJanitor)
    _G.__alvinSkinChangerJanitor = nil
end

-- Module loader
local modules = {}
local function import(moduleName)
    if modules[moduleName] then return modules[moduleName] end

    if type(readfile) == "function" then
        local paths = {
            "roblox_bloxstrike_SC/src/" .. moduleName .. ".lua",
            "Bloxstrike-Skinchanger/src/" .. moduleName .. ".lua",
            "src/" .. moduleName .. ".lua",
            moduleName .. ".lua"
        }
        for _, path in ipairs(paths) do
            local ok, content = pcall(readfile, path)
            if ok and content then
                local fn = loadstring(content)
                if fn then
                    local res = fn()
                    modules[moduleName] = res
                    return res
                end
            end
        end
    end

    -- Remote GitHub fallback with cache-busting timestamp
    local okHttp, remoteContent = pcall(function()
        return game:HttpGet("https://raw.githubusercontent.com/alvin12127/roblox_bloxstrike_SC/main/src/" .. moduleName .. ".lua?t=" .. tostring(os.time()))
    end)
    if okHttp and remoteContent and #remoteContent > 0 then
        local fn = loadstring(remoteContent)
        if fn then
            local res = fn()
            modules[moduleName] = res
            return res
        end
    end

    error("[Bloxstrike Skinchanger] Failed to import module: " .. tostring(moduleName))
end

-- Imports
local Config       = import("Config")
local Database     = import("Database")
local Engine       = import("Engine")
local API          = import("API")
local KnifeCatalog = import("KnifeCatalog")
local GunCatalog   = import("GunCatalog")
local GloveCatalog = import("GloveCatalog")
local LinoriaLib   = import("LinoriaLib")
local UIManager    = import("UIManager")

-- Bind subsystems
API.bind(Config, Database, Engine, KnifeCatalog, GunCatalog)
UIManager.bindCatalogs(KnifeCatalog, GunCatalog)
UIManager.bindGloveCatalog(GloveCatalog)
API.bindGloveCatalog(GloveCatalog)

-- Initialize Engine
API.init()

-- Cleanup routine
local function cleanup()
    UIManager.cleanup()
    API.cleanup()
    _G.__alvinSkinChangerJanitor = nil
end

-- Initialize UI with Knife catalog and gun controls
UIManager.init(Config, LinoriaLib, API, Database, cleanup)

-- Global exports
_G.SkinChanger = API
_G.__alvinSkinChangerJanitor = cleanup

print("@Discord_alvin6974. / Bloxstrike Skinchanger / Initialized with Visual 3D Catalog")
return API
