-- bullet tracer visuals
-- Draws the flight path of every bullet we fire. Every drawing property write is
-- guarded, because executor drawing implementations differ and a single failing
-- assign would otherwise kill the whole call silently.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local BulletTracer = {
    Initialized = false,
    RenderConn = nil
}

local active = {}   -- [line] = { expire, duration, baseThickness }
local pool = {}
local warnedUnavailable = false
local warnedReasons = {}

-- reports a blocking condition once per reason so the console stays readable
local function warnOnce(reason)
    warnedReasons[reason] = (warnedReasons[reason] or 0) + 1
    if warnedReasons[reason] > 3 then return end

    pcall(warn, "[Bloxstrike] Bullet tracer skipped: " .. reason)
end

-- some drawing implementations do not implement every optional property, so
-- optional level setters get their own pcall while the required ones are relied on
local function safeSet(obj, property, value)
    pcall(function() obj[property] = value end)
end

local function acquireLine()
    local line = table.remove(pool)
    if line then return line end

    local ok, created = pcall(function() return Drawing.new("Line") end)
    if ok and created then return created end

    if not warnedUnavailable then
        warnedUnavailable = true
        pcall(warn, "[Bloxstrike] Drawing.new('Line') unavailable - bullet tracers disabled")
    end

    return nil
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
                -- thickness is used for the fade because Transparency behaves the
                -- opposite way in some drawing implementations
                local fraction = math.clamp(remaining / info.duration, 0, 1)
                safeSet(line, "Thickness", math.max(info.baseThickness * fraction, 0.15))
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

    if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
        warnOnce("unexpected hit data geometry")
        return
    end

    distance = tonumber(distance) or 0

    if distance <= 0 then warnOnce("zero distance") return end

    local line = acquireLine()
    if not line then return end

    local camera = Workspace.CurrentCamera
    if not camera then releaseLine(line) warnOnce("no camera") return end

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
        return
    end

    if startSp.Z <= 0.01 or toSp.Z <= 0.01 then
        releaseLine(line)
        warnOnce("behind camera projection")
        return
    end

    local duration = Config.BULLET_TRACER_DURATION or 0.6
    local thickness = Config.BULLET_TRACER_THICKNESS or 1.5
    local color = Config.BULLET_TRACER_COLOR or Color3.fromRGB(186, 140, 255)

    -- every property write is pcall-protected: some drawing libraries reject a
    -- zero thickness or an unsupported optional property
    pcall(function()
        line.From = Vector2.new(startSp.X, startSp.Y)
        line.To = Vector2.new(toSp.X, toSp.Y)
    end)

    safeSet(line, "Color", color)
    safeSet(line, "Thickness", thickness)
    safeSet(line, "ZIndex", 6)
    safeSet(line, "Transparency", 1)

    pcall(function() line.Visible = true end)

    active[line] = {
        expire = os.clock() + duration,
        duration = duration,
        baseThickness = thickness
    }
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

    BulletTracer.Initialized = false
end

return BulletTracer
