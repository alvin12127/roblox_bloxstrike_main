-- grenade esp
-- Same proven technique as C4ESP: a cached name-substring scan of the workspace
-- plus fixed-pixel Drawing markers. It exists mainly as a second, independent
-- data point - if grenade ESP draws but C4 ESP does not, the problem is bomb
-- detection, and if neither draws it is the Drawing/UI layer.
--
-- Drawn per grenade instance: a box plus a label with the distance.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local MAX_MARKERS = 12

local GrenadeESP = {
    Initialized = false,
    Connection = nil,
    Items = {}      -- [1..MAX_MARKERS] = { Box, Label }
}

local storedConfig = nil

-- ==========================================================
-- Diagnostics (same multi-console approach as C4ESP)
-- ==========================================================
local function execLog(msg)
    local line = "[Bloxstrike] Grenade ESP: " .. msg
    local written = false

    pcall(function()
        if rconsoleprint then rconsoleprint(line .. "\n"); written = true end
    end)
    if not written then
        pcall(function()
            if consoleprint then consoleprint(line .. "\n"); written = true end
        end)
    end
    if not written then
        pcall(function()
            if printconsole then printconsole(line); written = true end
        end)
    end

    pcall(function() warn(line) end)
end

-- Logs only when the message changes, so the real reason a marker is missing
-- is never swallowed by a time-based throttle.
local lastState = ""
local function stateLog(msg)
    if msg ~= lastState then
        lastState = msg
        execLog(msg)
    end
end

local debugText = nil
local function ensureDebugLabel()
    if debugText then return end
    pcall(function()
        debugText = Drawing.new("Text")
        debugText.Size = 13
        debugText.Center = false
        debugText.Outline = true
        debugText.Color = Color3.fromRGB(120, 220, 255)
        debugText.Position = Vector2.new(16, 200)
        debugText.Visible = false
        debugText.Text = ""
    end)
end

-- ==========================================================
-- Drawing primitives
-- ==========================================================
local function makeItem(index)
    local item = GrenadeESP.Items[index]
    if item then return item end

    local okBox, box = pcall(function() return Drawing.new("Square") end)
    local okText, label = pcall(function() return Drawing.new("Text") end)

    if (not okBox) or (not okText) or (not box) or (not label) then
        if okBox and box then pcall(function() box:Remove() end) end
        if okText and label then pcall(function() label:Remove() end) end
        return nil
    end

    pcall(function()
        box.Thickness = 1.5
        box.Filled = false
        box.Visible = false
        box.ZIndex = 2

        label.Size = 13
        label.Center = true
        label.Outline = true
        label.Visible = false
        label.ZIndex = 3
    end)

    item = { Box = box, Label = label }
    GrenadeESP.Items[index] = item

    return item
end

local function hideItem(index)
    local item = GrenadeESP.Items[index]
    if not item then return end
    pcall(function() item.Box.Visible = false end)
    pcall(function() item.Label.Visible = false end)
end

local function hideAll()
    for index in pairs(GrenadeESP.Items) do
        hideItem(index)
    end
end

-- ==========================================================
-- Position resolution
-- ==========================================================
-- Instance:GetBoundingBox() returns (CFrame, Vector3) - CFrame first, size
-- second. Reading them the other way round yields nil for both.
local function resolvePosition(inst, depth)
    if not inst then return nil end
    depth = (depth or 0)

    if inst:IsA("BasePart") then
        local ok, p = pcall(function() return inst.Position end)
        if ok and p then return p end
        return nil
    end

    if inst:IsA("Attachment") then
        local ok, p = pcall(function() return inst.WorldPosition end)
        if ok and p then return p end
        return nil
    end

    if inst:IsA("Model") then
        local ok, cf = pcall(function() return inst:GetBoundingBox() end)
        if ok and cf and typeof(cf) == "CFrame" then
            local okPos, p = pcall(function() return cf.Position end)
            if okPos and p then return p end
        end

        if depth < 3 then
            local part = nil
            pcall(function() part = inst.PrimaryPart end)
            if not part then
                pcall(function() part = inst:FindFirstChildWhichIsA("BasePart") end)
            end
            if part then
                local okPos, p = pcall(function() return part.Position end)
                if okPos and p then return p end
            end
        end
    end

    if depth < 4 then
        local kids = nil
        pcall(function() kids = inst:GetChildren() end)
        if kids then
            for _, child in ipairs(kids) do
                local p = resolvePosition(child, depth + 1)
                if p then return p end
            end
        end
    end

    return nil
end

-- ==========================================================
-- Detection
-- ==========================================================
local GRENADE_HINTS = {
    "grenade",
    "hegrenade",
    "frag",
    "flashbang",
    "flash",
    "smokegrenade",
    "smoke",
    "molotov",
    "incendiary",
    "decoy",
}

local function isGrenadeName(name)
    if type(name) ~= "string" then return false end
    local lower = name:lower()

    for _, hint in ipairs(GRENADE_HINTS) do
        if lower:find(hint, 1, true) then
            return true
        end
    end

    return false
end

-- Walk the workspace three levels deep and collect every grenade-ish model or
-- part. Instances under a player rig are skipped (those are equipped weapons,
-- not dropped throwables) and so is the first person viewmodel.
local function findGrenades()
    local charsFolder = Workspace:FindFirstChild("Characters")
    local localChar = LocalPlayer and LocalPlayer.Character
    local camera = Workspace.CurrentCamera

    local results = {}

    local function consider(inst)
        if not inst then return end
        if not (inst:IsA("BasePart") or inst:IsA("Model") or inst:IsA("Folder")) then return end
        if charsFolder and inst:IsDescendantOf(charsFolder) then return end
        if localChar and inst:IsDescendantOf(localChar) then return end

        local underCamera = false
        pcall(function() underCamera = inst:IsDescendantOf(camera) end)
        if underCamera then return end

        if not isGrenadeName(inst.Name) then return end
        if not resolvePosition(inst, 0) then return end

        table.insert(results, inst)
    end

    pcall(function()
        for _, child in ipairs(Workspace:GetChildren()) do
            if child ~= charsFolder then
                consider(child)
                for _, sub in ipairs(child:GetChildren()) do
                    consider(sub)
                    for _, leaf in ipairs(sub:GetChildren()) do
                        consider(leaf)
                    end
                end
            end
        end
    end)

    return results
end

-- ==========================================================
-- Caching
-- ==========================================================
local SCAN_INTERVAL = 0.5

local cache = {
    grenades = {},
    lastScan = 0,
    valid = false
}

local function getGrenadesCached()
    local now = os.clock()
    if (not cache.valid) or ((now - cache.lastScan) >= SCAN_INTERVAL) then
        cache.valid = true
        cache.lastScan = now
        cache.grenades = findGrenades()
    end

    -- Drop entries whose instance left the game
    local alive = {}
    for _, inst in ipairs(cache.grenades) do
        if inst and inst.Parent then
            table.insert(alive, inst)
        end
    end
    cache.grenades = alive

    return cache.grenades
end

-- ==========================================================
-- Draw
-- ==========================================================
local function drawGrenade(camera, inst, index, color, boxSize, maxDistance)
    local item = makeItem(index)
    if not item then
        stateLog("draw failed - Drawing library unavailable")
        return false
    end

    local position = resolvePosition(inst, 0)
    if not position then
        hideItem(index)
        return false
    end

    local okScreen, screen = pcall(camera.WorldToViewportPoint, camera, position)
    if (not okScreen) or (not screen) or (screen.Z <= 0) then
        hideItem(index)
        return false
    end

    if screen.Z > maxDistance then
        hideItem(index)
        return false
    end

    local viewport = camera.ViewportSize
    if (screen.X < -boxSize) or (screen.Y < -boxSize)
        or (screen.X > viewport.X + boxSize) or (screen.Y > viewport.Y + boxSize) then
        hideItem(index)
        return false
    end

    local okDraw = pcall(function()
        item.Box.Position = Vector2.new(screen.X - (boxSize / 2), screen.Y - (boxSize / 2))
        item.Box.Size = Vector2.new(boxSize, boxSize)
        item.Box.Color = color
        item.Box.Visible = true

        item.Label.Text = string.format("%s  %dm", tostring(inst.Name), math.floor(screen.Z))
        item.Label.Position = Vector2.new(screen.X, screen.Y - (boxSize / 2) - 16)
        item.Label.Color = color
        item.Label.Visible = true
    end)

    if not okDraw then
        hideItem(index)
        return false
    end

    return true
end

-- ==========================================================
-- Update loop
-- ==========================================================
local function update()
    if not storedConfig then return end

    local enabled = storedConfig.GRENADE_ESP_ENABLED
    if enabled == nil then enabled = false end

    if not enabled then
        hideAll()
        ensureDebugLabel()
        pcall(function()
            if debugText then debugText.Visible = false end
        end)
        lastState = ""
        return
    end

    local camera = Workspace.CurrentCamera
    if not camera then
        hideAll()
        return
    end

    local boxSize = tonumber(storedConfig.GRENADE_ESP_BOX_SIZE) or 26
    local maxDistance = tonumber(storedConfig.GRENADE_ESP_MAX_DISTANCE) or 800
    local color = storedConfig.GRENADE_ESP_COLOR or Color3.fromRGB(120, 220, 255)

    local grenades = getGrenadesCached()

    -- Each grenade gets its OWN marker slot, keyed by its position in the scan.
    -- Keying off a running "drawn" counter would make every grenade reuse the
    -- same slot whenever an earlier one failed to draw, and the trailing hide
    -- sweep would then wipe markers that had already been drawn.
    local used = 0
    for index, inst in ipairs(grenades) do
        if used >= MAX_MARKERS then break end
        used = used + 1
        drawGrenade(camera, inst, used, color, boxSize, maxDistance)
    end

    -- Hide any leftover slots from a previous frame
    for index = (used + 1), MAX_MARKERS do
        hideItem(index)
    end

    local drawn = 0
    for index = 1, used do
        local item = GrenadeESP.Items[index]
        if item and item.Box and item.Box.Visible then drawn = drawn + 1 end
    end

    ensureDebugLabel()
    pcall(function()
        if debugText then
            debugText.Visible = true
            debugText.Text = string.format(
                "Grenade ESP  enabled=%s\nfound=%d\ndrawn=%d",
                tostring(enabled), #grenades, drawn
            )
        end
    end)

    if drawn > 0 then
        stateLog("drawing " .. tostring(drawn) .. " grenade marker(s) - Drawing layer is working")
    elseif #grenades == 0 then
        stateLog("no grenade instances found in workspace yet")
    else
        stateLog("found " .. tostring(#grenades) .. " grenade(s) but none were on screen or within range")
    end
end

function GrenadeESP.init(Config)
    if GrenadeESP.Initialized then return end
    GrenadeESP.Initialized = true

    storedConfig = Config

    GrenadeESP.Connection = RunService.RenderStepped:Connect(function()
        pcall(update)
    end)
end

function GrenadeESP.cleanup()
    if GrenadeESP.Connection then
        pcall(function() GrenadeESP.Connection:Disconnect() end)
        GrenadeESP.Connection = nil
    end

    hideAll()

    if debugText then
        pcall(function() debugText:Remove() end)
        debugText = nil
    end

    for index, item in pairs(GrenadeESP.Items) do
        pcall(function()
            item.Box:Remove()
            item.Label:Remove()
        end)
        GrenadeESP.Items[index] = nil
    end

    cache.grenades = {}
    cache.valid = false
    lastState = ""

    storedConfig = nil
    GrenadeESP.Initialized = false
end

return GrenadeESP
