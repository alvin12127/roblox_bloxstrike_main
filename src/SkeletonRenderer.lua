-- skeleton and esp renderer
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local Camera = Workspace.CurrentCamera
local EPS = 0.01

local SkeletonRenderer = {}

local BODY_PARTS = {
    Head = true, UpperTorso = true, LowerTorso = true, Torso = true,
    HumanoidRootPart = true, LeftUpperArm = true, LeftLowerArm = true, LeftHand = true,
    RightUpperArm = true, RightLowerArm = true, RightHand = true,
    LeftUpperLeg = true, LeftLowerLeg = true, LeftFoot = true,
    RightUpperLeg = true, RightLowerLeg = true, RightFoot = true
}

-- the equipped weapon lives on the player as a json encoded "CurrentEquipped"
-- attribute, same shape the damage engine already parses for the local player
local function readAttributeName(player, attributeName)
    local attr = player:GetAttribute(attributeName)
    if attr == nil then return nil end

    if typeof(attr) == "string" then
        local ok, parsed = pcall(HttpService.JSONDecode, HttpService, attr)
        if ok and type(parsed) == "table" and type(parsed.Name) == "string" then
            return parsed.Name
        end
        return nil
    end

    if typeof(attr) == "table" and attr.Name then
        return tostring(attr.Name)
    end

    return nil
end

-- falls back to whatever non-body model is attached to the rig
local function scanRigForItem(char)
    for _, child in ipairs(char:GetChildren()) do
        local isItem = child:IsA("Tool") or child:IsA("Model")
        if isItem and not BODY_PARTS[child.Name] then
            return child.Name
        end
    end
    return nil
end

-- decoded item names are cached per player so the json parse does not run
-- every frame for every enemy (weak keys so dropped players are collected)
local itemCache = setmetatable({}, { __mode = "k" })

local function getEquippedItem(char)
    local player = Players:FindFirstChild(char.Name)

    if player then
        local raw = player:GetAttribute("CurrentEquipped")

        if raw ~= nil then
            local entry = itemCache[player]

            if (not entry) or entry.raw ~= raw then
                entry = { raw = raw, name = readAttributeName(player, "CurrentEquipped") }
                itemCache[player] = entry
            end

            if entry.name and entry.name ~= "" then
                return entry.name
            end
        end

        local fallback = readAttributeName(player, "CurrentWeapon") or readAttributeName(player, "Equipped")
        if fallback and fallback ~= "" then
            return fallback
        end
    end

    return scanRigForItem(char)
end

-- r15 bone pairs
local BONE_PAIRS = {
    {"Head", "UpperTorso"},
    {"UpperTorso", "LowerTorso"},
    {"UpperTorso", "LeftUpperArm"},
    {"LeftUpperArm", "LeftLowerArm"},
    {"LeftLowerArm", "LeftHand"},
    {"UpperTorso", "RightUpperArm"},
    {"RightUpperArm", "RightLowerArm"},
    {"RightLowerArm", "RightHand"},
    {"LowerTorso", "LeftUpperLeg"},
    {"LeftUpperLeg", "LeftLowerLeg"},
    {"LeftLowerLeg", "LeftFoot"},
    {"LowerTorso", "RightUpperLeg"},
    {"RightUpperLeg", "RightLowerLeg"},
    {"RightLowerLeg", "RightFoot"}
}

function SkeletonRenderer.create()
    local obj = {
        Bones = {},
        ViewAngle = Drawing.new("Line"),
        HpBg = Drawing.new("Line"),
        HpFill = Drawing.new("Line"),
        NameText = Drawing.new("Text"),
        ItemText = Drawing.new("Text"),
        Box = Drawing.new("Square"),
        BoxLines = {},
        Arrow = Drawing.new("Triangle")
    }

    -- corner-only mode needs the box in eight segments: two per corner
    for i = 1, 8 do
        local seg = Drawing.new("Line")
        seg.Thickness = 1.5
        seg.ZIndex = 2
        seg.Visible = false
        obj.BoxLines[i] = seg
    end

    for i = 1, #BONE_PAIRS do
        local line = Drawing.new("Line")
        line.Thickness = 1.5
        line.ZIndex = 1
        line.Visible = false
        obj.Bones[i] = line
    end

    obj.ViewAngle.Thickness = 1.5
    obj.ViewAngle.Color = Color3.fromRGB(255, 255, 255)
    obj.ViewAngle.ZIndex = 2
    obj.ViewAngle.Visible = false

    obj.HpBg.Thickness = 4
    obj.HpBg.Color = Color3.fromRGB(15, 15, 15)
    obj.HpBg.ZIndex = 1
    obj.HpBg.Visible = false

    obj.HpFill.Thickness = 2
    obj.HpFill.ZIndex = 2
    obj.HpFill.Visible = false

    obj.NameText.Size = 13
    obj.NameText.Center = true
    obj.NameText.Outline = false
    obj.NameText.Color = Color3.fromRGB(240, 240, 240)
    obj.NameText.ZIndex = 3
    obj.NameText.Visible = false

    obj.ItemText.Size = 12
    obj.ItemText.Center = true
    obj.ItemText.Outline = false
    obj.ItemText.Color = Color3.fromRGB(200, 200, 210)
    obj.ItemText.ZIndex = 3
    obj.ItemText.Visible = false

    obj.Box.Filled = false
    obj.Box.Thickness = 1.5
    obj.Box.Color = Color3.fromRGB(240, 240, 245)
    obj.Box.ZIndex = 2
    obj.Box.Visible = false

    obj.Arrow.Filled = true
    obj.Arrow.Thickness = 1
    obj.Arrow.ZIndex = 5
    obj.Arrow.Visible = false

    return obj
end

-- names GUI (skeleton) uses ``minY``/``maxY`` as well, but these bounds come from
-- hitbox parts directly so box esp, name and item tags still work when the
-- skeleton itself is turned off
local BOUND_PARTS = {
    "Head", "UpperTorso", "Torso", "LowerTorso", "HumanoidRootPart",
    "LeftHand", "RightHand", "LeftFoot", "RightFoot"
}

local function computeCharacterBounds(char)
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    local onScreen = false

    for _, partName in ipairs(BOUND_PARTS) do
        local part = char:FindFirstChild(partName)
        if part and part:IsA("BasePart") then
            local sp = Camera:WorldToViewportPoint(part.Position)
            if sp.Z > 0 then
                onScreen = true
                if sp.X < minX then minX = sp.X end
                if sp.X > maxX then maxX = sp.X end
                if sp.Y < minY then minY = sp.Y end
                if sp.Y > maxY then maxY = sp.Y end
            end
        end
    end

    if not onScreen then
        return nil
    end

    return minX, maxX, minY, maxY
end

function SkeletonRenderer.hide(drawObj)
    for i = 1, #drawObj.Bones do
        drawObj.Bones[i].Visible = false
    end
    drawObj.ViewAngle.Visible = false
    drawObj.HpBg.Visible = false
    drawObj.HpFill.Visible = false
    if drawObj.NameText then drawObj.NameText.Visible = false end
    if drawObj.ItemText then drawObj.ItemText.Visible = false end
    if drawObj.Box then drawObj.Box.Visible = false end
    if drawObj.BoxLines then
        for _, seg in ipairs(drawObj.BoxLines) do
            seg.Visible = false
        end
    end
    if drawObj.Arrow then drawObj.Arrow.Visible = false end
end

function SkeletonRenderer.destroy(drawObj)
    for i = 1, #drawObj.Bones do
        pcall(function() drawObj.Bones[i]:Remove() end)
    end
    pcall(function() drawObj.ViewAngle:Remove() end)
    pcall(function() drawObj.HpBg:Remove() end)
    pcall(function() drawObj.HpFill:Remove() end)
    if drawObj.NameText then pcall(function() drawObj.NameText:Remove() end) end
    if drawObj.ItemText then pcall(function() drawObj.ItemText:Remove() end) end
    if drawObj.Box then pcall(function() drawObj.Box:Remove() end) end
    if drawObj.BoxLines then
        for _, seg in ipairs(drawObj.BoxLines) do
            pcall(function() seg:Remove() end)
        end
    end
    if drawObj.Arrow then pcall(function() drawObj.Arrow:Remove() end) end
end

-- line segment with near clip lerp
local function renderSegment(line, spA, spB, worldA, worldB, color, thickness)
    local za, zb = spA.Z, spB.Z

    if za > EPS and zb > EPS then
        line.From = Vector2.new(spA.X, spA.Y)
        line.To = Vector2.new(spB.X, spB.Y)
        line.Color = color
        line.Thickness = thickness or 1.5
        line.Visible = true
        return true
    elseif za <= EPS and zb <= EPS then
        line.Visible = false
        return false
    else
        local t = (za - EPS) / (za - zb)
        local clippedWorld = worldA:Lerp(worldB, t)
        local spc = Camera:WorldToViewportPoint(clippedWorld)
        local clip2D = Vector2.new(spc.X, spc.Y)

        if za > EPS then
            line.From = Vector2.new(spA.X, spA.Y)
            line.To = clip2D
        else
            line.From = clip2D
            line.To = Vector2.new(spB.X, spB.Y)
        end
        line.Color = color
        line.Thickness = thickness or 1.5
        line.Visible = true
        return true
    end
end

function SkeletonRenderer.render(drawObj, char, health, maxHealth, boneColor, baseColor, Config)
    local head = char:FindFirstChild("Head")
    local root = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("UpperTorso") or head
    if not head and not root then
        SkeletonRenderer.hide(drawObj)
        return
    end

    -- In third person mode, the camera is behind the player, so we need to
    -- adjust the ESP position to account for the camera offset
    local isThirdPerson = Config and Config.THIRDPERSON_ENABLED == true
    local camera = Workspace.CurrentCamera
    local cameraOffset = Vector3.new(0, 0, 0)
    
    if isThirdPerson and camera then
        -- Get the camera's position relative to the character
        local charRoot = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("UpperTorso")
        if charRoot then
            -- Calculate the offset from character to camera
            cameraOffset = camera.CFrame.Position - charRoot.Position
        end
    end

    local minX, maxX, minY, maxY = computeCharacterBounds(char)

    if minX == nil then
        -- off screen: keep the sentinels so the bone accumulation still works and
        -- the offscreen arrow block below stays reachable
        minX, maxX = math.huge, -math.huge
        minY, maxY = math.huge, -math.huge
    end

    local anyVisible = (maxX > -math.huge)
    local skeletonEnabled = not Config or (Config.SKELETON_ENABLED ~= false)
    local viewAngleEnabled = not Config or (Config.VIEWANGLE_ENABLED ~= false)

    local partPositions = {}
    local partScreenPoints = {}

    local function getPartPoint(partName)
        local cached = partScreenPoints[partName]
        if cached ~= nil then
            return cached, partPositions[partName]
        end
        local part = char:FindFirstChild(partName)
        if part and part:IsA("BasePart") then
            local pos = part.Position
            local sp = Camera:WorldToViewportPoint(pos)
            partPositions[partName] = pos
            partScreenPoints[partName] = sp
            return sp, pos
        end
        partScreenPoints[partName] = false
        return nil, nil
    end

    -- bones
    if skeletonEnabled and head then
        for i, pair in ipairs(BONE_PAIRS) do
            local spA, posA = getPartPoint(pair[1])
            local spB, posB = getPartPoint(pair[2])
            local line = drawObj.Bones[i]

            if spA and spB and posA and posB then
                local rendered = renderSegment(line, spA, spB, posA, posB, boneColor, 1.5)

                if rendered then
                    anyVisible = true
                    if spA.Z > EPS then
                        if spA.X < minX then minX = spA.X end
                        if spA.X > maxX then maxX = spA.X end
                        if spA.Y < minY then minY = spA.Y end
                        if spA.Y > maxY then maxY = spA.Y end
                    end
                    if spB.Z > EPS then
                        if spB.X < minX then minX = spB.X end
                        if spB.X > maxX then maxX = spB.X end
                        if spB.Y < minY then minY = spB.Y end
                        if spB.Y > maxY then maxY = spB.Y end
                    end
                end
            else
                line.Visible = false
            end
        end
    else
        for i = 1, #drawObj.Bones do
            drawObj.Bones[i].Visible = false
        end
    end

    -- view angle
    if skeletonEnabled and viewAngleEnabled and head then
        local spHead, headPos = getPartPoint("Head")
        if spHead and headPos then
            local camAttr = char:GetAttribute("CameraCFrame")
            local lookVector = (typeof(camAttr) == "CFrame" and camAttr.LookVector) or head.CFrame.LookVector
            local viewEndPos = headPos + (lookVector * 3.5)
            local spEnd = Camera:WorldToViewportPoint(viewEndPos)

            renderSegment(drawObj.ViewAngle, spHead, spEnd, headPos, viewEndPos, Color3.fromRGB(255, 255, 255), 1.5)
        else
            drawObj.ViewAngle.Visible = false
        end
    else
        drawObj.ViewAngle.Visible = false
    end

    -- health bar
    local hpNum = tonumber(health) or 100
    local maxHpNum = tonumber(maxHealth) or 100
    if maxHpNum <= 0 then maxHpNum = 100 end

    -- box esp (cube)
    if drawObj.Box then
        local cornersOnly = (Config and Config.BOX_ESP_CORNERS_ONLY == true)
        local showBox = (not Config or Config.BOX_ESP_ENABLED ~= false) and anyVisible

        pcall(function() drawObj.Box.Visible = showBox and (not cornersOnly) end)

        if showBox and (not cornersOnly) then
            pcall(function()
                drawObj.Box.Position = Vector2.new(minX - 5, minY - 5)
                drawObj.Box.Size = Vector2.new((maxX - minX) + 10, (maxY - minY) + 10)
                drawObj.Box.Color = boneColor
                drawObj.Box.Thickness = 1.5
            end)
        end

        -- corner only rendering with eight segments
        local linesEnabled = showBox and cornersOnly
        if linesEnabled then
            local x1, y1 = minX - 5, minY - 5
            local x2, y2 = maxX + 5, maxY + 5
            local width = x2 - x1
            local height = y2 - y1
            local arm = math.floor(math.min(width, height) * 0.18)
            arm = math.min(arm, 16)
            arm = math.max(arm, 6)

            local segs = {
                { Vector2.new(x1, y1), Vector2.new(x1 + arm, y1) },
                { Vector2.new(x1, y1), Vector2.new(x1, y1 + arm) },

                { Vector2.new(x2, y1), Vector2.new(x2 - arm, y1) },
                { Vector2.new(x2, y1), Vector2.new(x2, y1 + arm) },

                { Vector2.new(x1, y2), Vector2.new(x1 + arm, y2) },
                { Vector2.new(x1, y2), Vector2.new(x1, y2 - arm) },

                { Vector2.new(x2, y2), Vector2.new(x2 - arm, y2) },
                { Vector2.new(x2, y2), Vector2.new(x2, y2 - arm) }
            }

            for i = 1, #segs do
                local seg = drawObj.BoxLines[i]
                if seg then
                    pcall(function()
                        seg.From = segs[i][1]
                        seg.To = segs[i][2]
                        seg.Color = boneColor
                        seg.Thickness = 1.5
                        seg.Visible = true
                    end)
                end
            end
        elseif drawObj.BoxLines then
            for _, seg in ipairs(drawObj.BoxLines) do
                pcall(function() seg.Visible = false end)
            end
        end
    end

    if anyVisible and hpNum > 0 and minY < maxY then
        local barX = minX - 8
        local barHeight = math.max(maxY - minY, 12)
        local fraction = math.clamp(hpNum / maxHpNum, 0.01, 1.0)

        drawObj.HpBg.From = Vector2.new(barX, minY)
        drawObj.HpBg.To = Vector2.new(barX, maxY)
        drawObj.HpBg.Visible = true

        local fillTopY = maxY - (barHeight * fraction)
        drawObj.HpFill.From = Vector2.new(barX, maxY)
        drawObj.HpFill.To = Vector2.new(barX, fillTopY)
        drawObj.HpFill.Color = Color3.fromHSV(0.33 * fraction, 1, 1)
        drawObj.HpFill.Visible = true

        local midX = (minX + maxX) * 0.5

        -- name tag sits above the skeleton
        if drawObj.NameText then
            local showName = (not Config or Config.NAME_ESP_ENABLED ~= false)
            drawObj.NameText.Visible = showName

            if showName then
                drawObj.NameText.Text = char.Name
                drawObj.NameText.Position = Vector2.new(midX, minY - 18)
                drawObj.NameText.Color = boneColor
                drawObj.NameText.Outline = false
            end
        end

        -- equipped weapon takes the slot under the skeleton
        if drawObj.ItemText then
            local showItem = (not Config or Config.ITEM_ESP_ENABLED ~= false)
            local itemName = showItem and getEquippedItem(char) or nil

            drawObj.ItemText.Visible = (itemName ~= nil)

            if itemName then
                drawObj.ItemText.Text = itemName
                drawObj.ItemText.Position = Vector2.new(midX, maxY + 5)
                drawObj.ItemText.Color = boneColor
                drawObj.ItemText.Outline = false
            end
        end
    else
        drawObj.HpBg.Visible = false
        drawObj.HpFill.Visible = false
        if drawObj.NameText then drawObj.NameText.Visible = false end
        if drawObj.ItemText then drawObj.ItemText.Visible = false end
    end

    -- offscreen arrow
    local arrow = drawObj.Arrow
    local showArrows = (not Config or Config.OFFSCREEN_ARROWS ~= false)

    if showArrows and root and arrow then
        local tp = root.Position
        local dist = (tp - Camera.CFrame.Position).Magnitude
        local maxDist = (Config and Config.OFFSCREEN_ARROW_MAX_DIST) or 350
        local fadeStart = (Config and Config.OFFSCREEN_ARROW_FADE_DIST) or 80

        local headSp, headOn = head and Camera:WorldToViewportPoint(head.Position)
        local rootSp, rootOn = Camera:WorldToViewportPoint(tp)

        local isCharOnScreen = (anyVisible == true)
            or (headOn and headSp and headSp.Z > 0)
            or (rootOn and rootSp and rootSp.Z > 0)

        if isCharOnScreen or dist > maxDist then
            arrow.Visible = false
        else
            local fade = 1.0
            if dist > fadeStart then
                fade = 1.0 - ((dist - fadeStart) / (maxDist - fadeStart))
                fade = math.clamp(fade, 0, 1)
            end

            if fade < 0.04 then
                arrow.Visible = false
            else
                local vpSize = Camera.ViewportSize
                local center = vpSize * 0.5
                local rel = Camera.CFrame:PointToObjectSpace(tp)

                local dir
                if rel.Z > 0 then
                    local yawAngle = math.atan2(rel.X, -rel.Z)
                    dir = Vector2.new(math.sin(yawAngle), -math.cos(yawAngle))
                else
                    dir = Vector2.new(rel.X, -rel.Y)
                end

                if dir.Magnitude < 1e-3 then
                    dir = Vector2.new(0, 1)
                else
                    dir = dir.Unit
                end

                local perp = Vector2.new(-dir.Y, dir.X)
                local radius = math.min(center.X, center.Y) * (Config and Config.OFFSCREEN_ARROW_RADIUS or 0.72)
                local at = center + dir * radius
                local sz = (Config and Config.OFFSCREEN_ARROW_SIZE) or 13

                arrow.PointA = at + dir * sz
                arrow.PointB = at - dir * (sz * 0.45) + perp * (sz * 0.75)
                arrow.PointC = at - dir * (sz * 0.45) - perp * (sz * 0.75)
                arrow.Color = baseColor or boneColor
                arrow.Transparency = fade
                arrow.Visible = true
            end
        end
    else
        if arrow then arrow.Visible = false end
    end
end

return SkeletonRenderer
