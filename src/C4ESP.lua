-- c4 esp
-- Dedicated bomb tracker, kept completely separate from the grenade code.
--
-- Ground truth from the game dump:
--   * the player carrying the bomb has a "BombHolster" model parented to their
--     character (exactly one exists at a time, same as in CS)
--   * planted / dropped state comes from the local player's own attributes, the
--     same values the reference source reads for its bomb timer block.
--
-- What is drawn:
--   * "C4 Carrier" above whoever is holding the bomb
--   * a box plus a label on the physical bomb when it is on the ground, and the
--     remaining timer when it is planted.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local C4ESP = {
    Initialized = false,
    Connection = nil,
    Items = {}          -- [key] = { Box, Label }
}

local storedConfig = nil

local function getCamera()
    return Workspace.CurrentCamera
end

local function makeItem(key)
    local item = C4ESP.Items[key]

    if item then return item end

    local okBox, box = pcall(function() return Drawing.new("Square") end)
    local okText, label = pcall(function() return Drawing.new("Text") end)

    if (not okBox) or (not okText) then
        if okBox then pcall(function() box:Remove() end) end
        if okText then pcall(function() label:Remove() end) end
        return nil
    end

    pcall(function()
        box.Thickness = 1.5
        box.Filled = false
        box.Visible = false

        label.Size = 13
        label.Center = true
        label.Outline = true
        label.Visible = false
    end)

    item = { Box = box, Label = label }
    C4ESP.Items[key] = item

    return item
end

local function hideAll()
    for _, item in pairs(C4ESP.Items) do
        pcall(function()
            item.Box.Visible = false
            item.Label.Visible = false
        end)
    end
end

-- the bomb carrier is the only character with a BombHolster child
local function findBombCarrier()
    local characters = Workspace:FindFirstChild("Characters")
    if not characters then return nil end

    for _, character in ipairs(characters:GetChildren()) do
        if character:FindFirstChild("BombHolster") then
            return character
        end
    end

    return nil
end

local function isBombName(name)
    if type(name) ~= "string" then return false end

    if name == "C4" then return true end

    if name:lower():find("bomb", 1, true) then return true end

    return false
end

-- the physical bomb, anything outside the characters folder
local function findWorldBomb()
    local function scan(container)
        if not container then return nil end

        for _, child in ipairs(container:GetChildren()) do
            if child:IsA("Model") and isBombName(child.Name) then
                return child
            end
        end

        return nil
    end

    return scan(Workspace) or scan(Workspace:FindFirstChild("Debris"))
end

local function bombAttributes()
    local planted = false
    local timer = 0

    pcall(function()
        planted = (LocalPlayer:GetAttribute("BombPlanted") == true)
        timer = tonumber(LocalPlayer:GetAttribute("BombTimer")) or 0
    end)

    return planted, timer
end

local function drawCarrier(camera, character, color)
    local item = makeItem("Carrier")
    if not item then return end

    local part = character:FindFirstChild("Head") or character:FindFirstChild("UpperTorso")
    if not part then
        item.Box.Visible = false
        item.Label.Visible = false
        return
    end

    local ok, screen = pcall(camera.WorldToViewportPoint, camera, part.Position + Vector3.new(0, 2, 0))

    if (not ok) or (not screen) or (screen.Z <= 0) then
        item.Box.Visible = false
        item.Label.Visible = false
        return
    end

    local player = Players:FindFirstChild(character.Name)
    local shown = (player and player.DisplayName) or character.Name

    pcall(function()
        item.Label.Text = "C4 Carrier: " .. tostring(shown)
        item.Label.Position = Vector2.new(screen.X, screen.Y)
        item.Label.Color = color
        item.Label.Visible = true
        item.Box.Visible = false
    end)
end

local function drawWorldBomb(camera, model, color, label)
    local item = makeItem("World")
    if not item then return end

    local ok, box, center = pcall(function()
        return model:GetBoundingBox()
    end)

    if (not ok) or (not box) or (not center) then
        item.Box.Visible = false
        item.Label.Visible = false
        return
    end

    local okScreen, screen = pcall(camera.WorldToViewportPoint, camera, center.Position)

    if (not okScreen) or (not screen) or (screen.Z <= 0) then
        item.Box.Visible = false
        item.Label.Visible = false
        return
    end

    local size = box.Size
    local width = math.max(size.X, size.Y, size.Z, 2)

    pcall(function()
        item.Box.Position = Vector2.new(screen.X - (width / 2), screen.Y - (width / 2))
        item.Box.Size = Vector2.new(width, width)
        item.Box.Color = color
        item.Box.Visible = true

        item.Label.Text = label
        item.Label.Position = Vector2.new(screen.X, screen.Y - (width / 2) - 16)
        item.Label.Color = color
        item.Label.Visible = true
    end)
end

local function update()
    if not storedConfig then return end

    if storedConfig.C4_ESP_ENABLED ~= true then
        hideAll()
        return
    end

    local camera = getCamera()
    if not camera then
        hideAll()
        return
    end

    local color = Color3.fromRGB(255, 70, 70)

    local carrier = findBombCarrier()

    if carrier then
        drawCarrier(camera, carrier, color)
    else
        local carrierItem = C4ESP.Items["Carrier"]
        if carrierItem then
            pcall(function()
                carrierItem.Box.Visible = false
                carrierItem.Label.Visible = false
            end)
        end
    end

    local planted, timer = bombAttributes()
    local worldBomb = findWorldBomb()

    if worldBomb then
        local label

        if planted then
            label = string.format("C4 Planted  %.0fs", timer)
        else
            label = "C4 Dropped"
        end

        drawWorldBomb(camera, worldBomb, color, label)
    else
        local worldItem = C4ESP.Items["World"]
        if worldItem then
            pcall(function()
                worldItem.Box.Visible = false
                worldItem.Label.Visible = false
            end)
        end
    end
end

function C4ESP.init(Config)
    if C4ESP.Initialized then return end
    C4ESP.Initialized = true

    storedConfig = Config

    C4ESP.Connection = RunService.RenderStepped:Connect(function()
        pcall(update)
    end)
end

function C4ESP.cleanup()
    if C4ESP.Connection then
        pcall(function() C4ESP.Connection:Disconnect() end)
        C4ESP.Connection = nil
    end

    hideAll()

    for key, item in pairs(C4ESP.Items) do
        pcall(function()
            item.Box:Remove()
            item.Label:Remove()
        end)
        C4ESP.Items[key] = nil
    end

    storedConfig = nil
    C4ESP.Initialized = false
end

return C4ESP
