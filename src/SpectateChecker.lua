-- spectator indicator
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local SpectateChecker = {}
local label = nil
local guiInstance = nil

local function getGuiParent()
    if type(gethui) == "function" then
        local ok, h = pcall(gethui)
        if ok and h then return h end
    end
    local ok, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok and cg then return cg end
    return LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
end

function SpectateChecker.init(Config)
    if not Config.SPECTATE_CHECKER_ENABLED then return nil end

    local parent = getGuiParent()
    if not parent then return nil end

    pcall(function()
        local existing = parent:FindFirstChild("AG_SpectatorUI")
        if existing then
            existing:Destroy()
        end

        local gui = Instance.new("ScreenGui")
        gui.Name = "AG_SpectatorUI"
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 1000000
        gui.Parent = parent
        guiInstance = gui

        label = Instance.new("TextLabel")
        label.Name = "SpectatorCount"
        label.Size = UDim2.new(0, 200, 0, 24)
        label.Position = UDim2.new(0.5, -100, 0.08, 0)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.GothamBold
        label.TextSize = 15
        label.TextStrokeTransparency = 0.25
        label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        label.TextColor3 = Color3.fromRGB(255, 75, 75)
        label.Text = ""
        label.Visible = false
        label.Parent = gui
    end)

    return label
end

function SpectateChecker.update(Config)
    if not label or not Config.SPECTATE_CHECKER_ENABLED then return end

    pcall(function()
        local specCount = LocalPlayer:GetAttribute("Spectators") or 0
        if specCount > 0 then
            label.Visible = true
            label.Text = string.format("👁️ Spectating You: %d", specCount)
        else
            label.Visible = false
            label.Text = ""
        end
    end)
end

function SpectateChecker.cleanup()
    if guiInstance then
        pcall(function() guiInstance:Destroy() end)
        guiInstance = nil
    end
    label = nil
end

return SpectateChecker
