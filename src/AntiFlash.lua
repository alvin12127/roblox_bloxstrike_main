-- antiflash
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local FlashEffect = require(ReplicatedStorage.Components.Common.VFXLibary.FlashEffect)
local CaptureController = require(ReplicatedStorage.Controllers.CaptureController)
local Promise = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Promise"))

local AntiFlash = {
    Connections = {},
    IndicatorGui = nil,
    Initialized = false
}

local originalCaptureScreenshot = nil

function AntiFlash.init(Config)
    if AntiFlash.Initialized then return end
    AntiFlash.Initialized = true

    -- disable flash screenshot
    if not _G.__originalCaptureScreenshot then
        _G.__originalCaptureScreenshot = CaptureController.CaptureScreenshot
    end
    originalCaptureScreenshot = _G.__originalCaptureScreenshot

    CaptureController.CaptureScreenshot = function(callback)
        if Config.ANTI_FLASH_ENABLED then
            return Promise.reject("Flash snapshot burn-in disabled by AntiFlash")
        end
        return originalCaptureScreenshot(callback)
    end

    -- indicator overlay
    local indicatorGui = Instance.new("ScreenGui")
    indicatorGui.Name = "AntiFlashIndicator"
    indicatorGui.DisplayOrder = 999
    indicatorGui.IgnoreGuiInset = true
    indicatorGui.ResetOnSpawn = false

    local overlayFrame = Instance.new("Frame")
    overlayFrame.Name = "IndicatorOverlay"
    overlayFrame.Size = UDim2.new(1, 0, 1, 0)
    overlayFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    overlayFrame.BackgroundTransparency = 1
    overlayFrame.BorderSizePixel = 0
    overlayFrame.Parent = indicatorGui

    indicatorGui.Parent = PlayerGui
    AntiFlash.IndicatorGui = indicatorGui

    -- render loop
    local isFlashedPrev = false

    local renderConn = RunService.RenderStepped:Connect(function()
        if not Config.ANTI_FLASH_ENABLED then
            overlayFrame.BackgroundTransparency = 1
            return
        end

        local officialGui = PlayerGui:FindFirstChild("FlashbangEffect")
        if officialGui then
            for _, obj in ipairs(officialGui:GetDescendants()) do
                if obj:IsA("GuiObject") then
                    obj.Visible = false
                end
            end
        end

        local cc = Lighting:FindFirstChild("FlashbangColorCorrection")
        if cc then
            cc.Brightness = 0
            cc.Saturation = 0
            cc.Enabled = false
        end

        local isFlashed = FlashEffect.IsFlashed()
        if isFlashed then
            overlayFrame.BackgroundTransparency = Config.ANTI_FLASH_TRANSPARENCY or 0.85
            isFlashedPrev = true
        elseif isFlashedPrev then
            isFlashedPrev = false
            TweenService:Create(overlayFrame, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                BackgroundTransparency = 1
            }):Play()
        end
    end)
    table.insert(AntiFlash.Connections, renderConn)
end

function AntiFlash.cleanup()
    if originalCaptureScreenshot then
        CaptureController.CaptureScreenshot = originalCaptureScreenshot
    end
    for _, c in ipairs(AntiFlash.Connections) do
        pcall(function() c:Disconnect() end)
    end
    AntiFlash.Connections = {}
    if AntiFlash.IndicatorGui then
        pcall(function() AntiFlash.IndicatorGui:Destroy() end)
        AntiFlash.IndicatorGui = nil
    end
    AntiFlash.Initialized = false
    _G.__originalCaptureScreenshot = nil
end

return AntiFlash
