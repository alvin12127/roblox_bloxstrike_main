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

local function smoothStep(t)
    t = math.clamp(t, 0, 1)
    return t * t * (3 - 2 * t)
end

local function safeSet(obj, property, value)
    pcall(function() obj[property] = value end)
end

-- how long the beam takes to shoot out of the muzzle
local GROW_TIME = 0.07

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
        local camera = Workspace.CurrentCamera
        if not camera then return end

        for line, info in pairs(active) do
            local remaining = info.expire - now

            if remaining <= 0 then
                active[line] = nil
                releaseLine(line)
            else
                -- The world endpoints are re-projected every frame. A drawing line
                -- only stores screen coordinates, so without this the tracer would
                -- stay glued to the same spot on screen while the camera moves.
                local okFrom, fromSp = pcall(camera.WorldToViewportPoint, camera, info.startWorld)
                local okTo, toSp = pcall(camera.WorldToViewportPoint, camera, info.endWorld)

                if (not okFrom) or (not okTo) or (not fromSp) or (not toSp)
                    or (fromSp.Z <= 0.01) or (toSp.Z <= 0.01) then

                    pcall(function() line.Visible = false end)
                else
                    -- the beam shoots out of the muzzle over a few frames and
                    -- then eases away, instead of popping in as a hard full line
                    local elapsed = info.duration - remaining
                    local grow = info.growTime and info.growTime > 0
                        and smoothStep(elapsed / info.growTime) or 1

                    local endWorld = (grow >= 1) and info.endWorld
                        or info.startWorld:Lerp(info.endWorld, grow)

                    local okEnd, endSp = pcall(camera.WorldToViewportPoint, camera, endWorld)

                    if (not okEnd) or (not endSp) or (endSp.Z <= 0.01) then
                        pcall(function() line.Visible = false end)
                    else
                        pcall(function()
                            line.From = Vector2.new(fromSp.X, fromSp.Y)
                            line.To = Vector2.new(endSp.X, endSp.Y)
                        end)

                        local fraction = smoothStep(remaining / info.duration)
                        safeSet(line, "Thickness", math.max(info.baseThickness * fraction, 0.12))

                        pcall(function() line.Visible = true end)
                    end
                end
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

    -- some callers hand over a scaled vector rather than a unit one, which would
    -- push the end point far outside the viewport and make the line invisible
    if direction.Magnitude > 0 then
        direction = direction.Unit
    end

    distance = math.clamp(distance, 0.5, 2000)

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

    -- A shot always leaves the crosshair, so the impact point always projects to
    -- the exact screen centre. Drawing camera -> impact would be a zero length
    -- line and never visible, so the beam starts at the muzzle instead: the view
    -- model gun sits down and to the right of the camera. The first slice is then
    -- trimmed off, because a line starting inside our own body is not visible.
    local cameraCFrame = camera.CFrame
    local muzzlePoint = cameraCFrame.Position
        + (cameraCFrame.RightVector * 0.38)
        + (cameraCFrame.UpVector * -0.28)
        + (cameraCFrame.LookVector * 0.75)

    local startPoint = muzzlePoint:Lerp(endPoint, 0.12)

    local okStart, startSp = pcall(camera.WorldToViewportPoint, camera, startPoint)
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

    -- a degenerate line draws nothing, which is what a camera origin produced
    if (Vector2.new(startSp.X, startSp.Y) - Vector2.new(toSp.X, toSp.Y)).Magnitude < 3 then
        releaseLine(line)
        log(3, "degenerate: start and end coincide")
        return
    end

    -- a zero duration would release the line on the very next frame
    local duration = math.max(tonumber(Config.BULLET_TRACER_DURATION) or 0.6, 0.05)
    local thickness = Config.BULLET_TRACER_THICKNESS or 1.5
    local color = Config.BULLET_TRACER_COLOR or Color3.fromRGB(186, 140, 255)

    -- From/To/Thickness/Visible are driven by the render loop from here on, so
    -- they are deliberately not set at creation: the grow animation has to start
    -- from the muzzle rather than appear as a finished full length line.
    local okColor = pcall(function() line.Color = color end)
    safeSet(line, "ZIndex", 6)

    -- 0.5 is visible under either transparency convention
    safeSet(line, "Transparency", 0.5)

    if not okColor then log(3, "failed: Color") end

    active[line] = {
        expire = os.clock() + duration,
        duration = duration,
        baseThickness = thickness,
        growTime = GROW_TIME,
        startWorld = startPoint,
        endWorld = endPoint
    }

    log(3, string.format(
        "drew ok from=(%.0f,%.0f) to=(%.0f,%.0f) dist=%.1f dur=%.2f",
        startSp.X, startSp.Y, toSp.X, toSp.Y, distance, duration
    ))
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
