-- skeleton and esp renderer
local Workspace = game:GetService("Workspace")
local Camera = Workspace.CurrentCamera
local EPS = 0.01

local SkeletonRenderer = {}

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
        Arrow = Drawing.new("Triangle")
    }

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

    obj.Arrow.Filled = true
    obj.Arrow.Thickness = 1
    obj.Arrow.ZIndex = 5
    obj.Arrow.Visible = false

    return obj
end

function SkeletonRenderer.hide(drawObj)
    for i = 1, #drawObj.Bones do
        drawObj.Bones[i].Visible = false
    end
    drawObj.ViewAngle.Visible = false
    drawObj.HpBg.Visible = false
    drawObj.HpFill.Visible = false
    if drawObj.NameText then drawObj.NameText.Visible = false end
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

    local minX, maxX = math.huge, -math.huge
    local minY, maxY = math.huge, -math.huge
    local anyVisible = false
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

    if skeletonEnabled and anyVisible and hpNum > 0 and minY < maxY then
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

        -- name tag
        if drawObj.NameText then
            local midX = (minX + maxX) * 0.5
            local nameY = maxY + 4
            drawObj.NameText.Text = char.Name
            drawObj.NameText.Position = Vector2.new(midX, nameY)
            drawObj.NameText.Color = boneColor
            drawObj.NameText.Outline = false
            drawObj.NameText.Visible = true
        end
    else
        drawObj.HpBg.Visible = false
        drawObj.HpFill.Visible = false
        if drawObj.NameText then drawObj.NameText.Visible = false end
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
