-- bullet tracer visuals
-- Draws the flight path of every bullet we fire. Note that in this drawing
-- implementation Transparency 1 is fully opaque and 0 is invisible, matching how
-- the offscreen arrows fade out.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Camera = Workspace.CurrentCamera

local BulletTracer = {
    Initialized = false,
    RenderConn = nil
}

local active = {}   -- [line] = { expire, duration }
local pool = {}

local function acquireLine()
    local line = table.remove(pool)
    if line then return line end

    local ok, created = pcall(function() return Drawing.new("Line") end)
    if ok and created then return created end

    return nil
end

local function releaseLine(line)
    line.Visible = false
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
                line.Transparency = math.clamp(remaining / info.duration, 0, 1)
            end
        end
    end)
end

-- called with the raw hit data right after a bullet resolves
function BulletTracer.push(hitData, Config)
    if Config.BULLET_TRACER_ENABLED ~= true then return end
    if type(hitData) ~= "table" then return end

    local origin = hitData.Origin
    local direction = hitData.Direction
    local distance = hitData.Distance

    if not origin or not direction or not distance then return end
    if distance <= 0 then return end

    local line = acquireLine()
    if not line then return end

    local endPoint = origin + (direction * distance)

    local okFrom, fromSp = pcall(Camera.WorldToViewportPoint, Camera, origin)
    local okTo, toSp = pcall(Camera.WorldToViewportPoint, Camera, endPoint)

    if (not okFrom) or (not okTo) or (not fromSp) or (not toSp) then
        releaseLine(line)
        return
    end

    if fromSp.Z <= 0.01 or toSp.Z <= 0.01 then
        releaseLine(line)
        return
    end

    local duration = Config.BULLET_TRACER_DURATION or 0.6

    line.From = Vector2.new(fromSp.X, fromSp.Y)
    line.To = Vector2.new(toSp.X, toSp.Y)
    line.Color = Config.BULLET_TRACER_COLOR or Color3.fromRGB(186, 140, 255)
    line.Thickness = Config.BULLET_TRACER_THICKNESS or 1.5
    line.Transparency = 1
    line.Visible = true

    active[line] = {
        expire = os.clock() + duration,
        duration = duration
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
