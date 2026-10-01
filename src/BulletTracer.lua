-- bullet tracer visuals
-- Every drawing property write is pcall protected, because executor drawing
-- implementations differ and one failing assign would otherwise end the whole
-- call silently. Transparency is convention dependent in drawing libraries
-- (some treat 1 as opaque, some treat it as invisible), so the fade is done
-- through thickness which behaves the same everywhere, and 0.5 stays visible
-- under either convention.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local BulletTracer = {
    Initialized = false,
    RenderConn = nil
}

local active = {}   -- [line] = { expire, duration, baseThickness }
local pool = {}

-- diagnostics only fire a handful of times so the console stays readable
local diagnostics = {}
local function log(count, message)
    diagnostics[message] = (diagnostics[message] or 0) + 1
    if diagnostics[message] > count then return end
    pcall(warn, "[Bloxstrike] tracer " .. message)
end

local function safeSet(obj, property, value)
    pcall(function() obj[property] = value end)
end

local function acquireLine()
    local line = table.remove(pool)
    if line then return line end

    local ok, created = pcall(function() return Drawing.new("Line") end)
    if not ok or not created then
        log(3, "unavailable: Drawing.new('Line') failed")
        return nil
    end

    return created
end

local function releaseLine(line)
    pcall(function() line.Visible = false end)
    table.insert(pool, line)
end

function BulletTracer.init(Config)
    if BulletTracer.Initialized then return end
    BulletTracer.Initialized = true

    BulletTracer.RenderConn = RunService.RenderStepped:Connect(function()
        local now = os.clock()

        for line, info in pairs(active) do
            local remaining = info.expire - now

            if remaining <= 0 then
                active[line] = nil
                releaseLine(line)
            else
                local fraction = math.clamp(remaining / info.duration, 0, 1)
                safeSet(line, "Thickness", math.max(info.baseThickness * fraction, 0.12))
            end
        end
    end)
end

-- called with the raw hit data right after a bullet resolves
function BulletTracer.push(hitData, Config)
    if (not Config) or (Config.BULLET_TRACER_ENABLED ~= true) then return end
    if type(hitData) ~= "table" then return end

    local origin = hitData.Origin
    local direction = hitData.Direction
    local distance = hitData.Distance

    -- Luau reports Vector3 values through typeof(), never through type(), which
    -- returns the raw metatable kind. Using type() here made every valid shot
    -- look like bad geometry and blocked the tracer entirely.
    if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
        log(3, "unexpected geometry: origin/direction not Vector3")
        return
    end

    distance = tonumber(distance) or 0
    if distance <= 0 then
        log(3, "unexpected geometry: distance <= 0")
        return
    end

    local line = acquireLine()
    if not line then return end

    -- fetched per call: CurrentCamera can be recreated on respawn
    local camera = Workspace.CurrentCamera
    if not camera then
        releaseLine(line)
        log(3, "no current camera")
        return
    end

    local endPoint = origin + (direction * distance)

    -- the ray origin sits at the camera itself where the projected depth is 0,
    -- which makes the start point degenerate. nudge it forward along the ray.
    local startPoint = origin
    local okStart, startSp = pcall(camera.WorldToViewportPoint, camera, startPoint)

    if (not okStart) or (not startSp) or (startSp.Z <= 0.05) then
        startPoint = origin + (direction * 0.3)
        okStart, startSp = pcall(camera.WorldToViewportPoint, camera, startPoint)
    end

    local okTo, toSp = pcall(camera.WorldToViewportPoint, camera, endPoint)

    if (not okStart) or (not okTo) or (not startSp) or (not toSp) then
        releaseLine(line)
        log(3, "projection failed")
        return
    end

    if startSp.Z <= 0.01 or toSp.Z <= 0.01 then
        releaseLine(line)
        log(3, "projection behind camera")
        return
    end

    local duration = Config.BULLET_TRACER_DURATION or 0.6
    local thickness = Config.BULLET_TRACER_THICKNESS or 1.5
    local color = Config.BULLET_TRACER_COLOR

    -- required properties first, optional ones after
    pcall(function()
        line.From = Vector2.new(startSp.X, startSp.Y)
        line.To = Vector2.new(toSp.X, toSp.Y)
        line.Color = color or Color3.fromRGB(186, 140, 255)
        line.Thickness = thickness
        line.Visible = true
    end)

    safeSet(line, "ZIndex", 6)

    -- 0.5 is visible under either transparency convention
    safeSet(line, "Transparency", 0.5)

    active[line] = {
        expire = os.clock() + duration,
        duration = duration,
        baseThickness = thickness
    }

    log(3, "drew ok")
end

function BulletTracer.cleanup()
    if BulletTracer.RenderConn then
        pcall(function() BulletTracer.RenderConn:Disconnect() end)
        BulletTracer.RenderConn = nil
    end

    for line in pairs(active) do
        releaseLine(line)
    end
    active = {}

    for _, line in ipairs(pool) do
        pcall(function() line:Remove() end)
    end
    pool = {}

    diagnostics = {}
    BulletTracer.Initialized = false
end

return BulletTracer
