-- esp manager
local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

local ESPManager = {}

local CharHL = require(ReplicatedStorage.Classes.CharacterHighlight)
local _G_originalUpdateState = CharHL.UpdateState
_G.__originalUpdateState = _G_originalUpdateState

local coreContainer = nil
local skeletonDrawings = {}
local occlusionCache = {}
local occlusionTime = {}

local function darkenColor(color, factor)
    factor = factor or 0.45
    return Color3.new(color.R * factor, color.G * factor, color.B * factor)
end

function ESPManager.init(Config, Utils, SkeletonRenderer)
    function CharHL.UpdateState(self, state)
        if not Config.ESP_HIGHLIGHT_ENABLED then
            if self.Highlight then
                self.Highlight.Enabled = false
            end
            self.IsEnabled = false
            return
        end
        return _G_originalUpdateState(self, state)
    end

    coreContainer = CoreGui:FindFirstChild("AG_Persistent_ESP")
    if not coreContainer then
        coreContainer = Instance.new("Folder")
        coreContainer.Name = "AG_Persistent_ESP"
        coreContainer.Parent = CoreGui
    end
    coreContainer:ClearAllChildren()

    return coreContainer
end

function ESPManager.update(Config, Utils, SkeletonRenderer)
    if Config.ESP_ENABLED == false then
        for _, drawObj in pairs(skeletonDrawings) do
            SkeletonRenderer.hide(drawObj)
        end
        return
    end

    local charsFolder = Workspace:FindFirstChild("Characters")
    if not charsFolder then
        for charInstance, drawObj in pairs(skeletonDrawings) do
            SkeletonRenderer.destroy(drawObj)
        end
        table.clear(skeletonDrawings)
        return
    end

    local myChar = Utils.getAliveCharacter(LocalPlayer)
    local seen = {}

    local function processModel(char)
        if not char or not char:IsA("Model") or char.Parent ~= charsFolder then return end
        if char.Name == LocalPlayer.Name or (myChar and char == myChar) then return end
        if char:GetAttribute("Dead") == true then return end

        local hp, maxHp = Utils.getCharacterHealth(char)
        if hp <= 0 then return end

        local p = Players:FindFirstChild(char.Name)
        local team = Utils.getTeam(p, char)
        if not team or (team ~= "Counter-Terrorists" and team ~= "CT" and team ~= "Terrorists" and team ~= "T") then
            return
        end

        local isEnemy = Utils.isEnemy(p, char)
        if Config.DISABLE_TEAMMATES and not isEnemy then
            return
        end

        seen[char] = true

        local isAimActive = (type(Config.isSilentAimActive) == "function") and Config.isSilentAimActive() or (Config.SILENT_AIM_ENABLED ~= false)
        local isTarget = isAimActive and (Config.CurrentTargetChar ~= nil) and (char == Config.CurrentTargetChar)
        local baseColor

        if isTarget then
            baseColor = Config.TARGET_COLOR
        else
            local isCT = (team == "Counter-Terrorists" or team == "CT")
            baseColor = isCT and Config.CT_COLOR or Config.T_COLOR
        end

        -- occlusion color dimming (10hz)
        local isOccluded = false
        if Config.OCCLUSION_CHECK_ENABLED then
            local now = os.clock()
            if (now - (occlusionTime[char] or 0)) > 0.1 then
                occlusionCache[char] = Utils.isTargetOccluded(char)
                occlusionTime[char] = now
            end
            isOccluded = occlusionCache[char] or false
        end

        local boneColor = isOccluded and darkenColor(baseColor, Config.OCCLUDED_COLOR_FACTOR) or baseColor

        if Config.SKELETON_ENABLED or Config.OFFSCREEN_ARROWS then
            local drawObj = skeletonDrawings[char]
            if not drawObj then
                drawObj = SkeletonRenderer.create()
                skeletonDrawings[char] = drawObj
            end

            SkeletonRenderer.render(drawObj, char, hp, maxHp, boneColor, baseColor, Config)
        else
            local drawObj = skeletonDrawings[char]
            if drawObj then
                SkeletonRenderer.hide(drawObj)
            end
        end
    end

    for _, child in ipairs(charsFolder:GetChildren()) do
        if child:IsA("Model") then
            processModel(child)
        end
    end

    -- remove dead drawings
    for charInstance, drawObj in pairs(skeletonDrawings) do
        if not seen[charInstance] then
            SkeletonRenderer.hide(drawObj)
            local hp = Utils.getCharacterHealth(charInstance)
            if not charInstance.Parent or charInstance.Parent ~= charsFolder or charInstance:GetAttribute("Dead") == true or hp <= 0 then
                SkeletonRenderer.destroy(drawObj)
                skeletonDrawings[charInstance] = nil
            end
        end
    end
end

function ESPManager.cleanup(SkeletonRenderer)
    if _G.__originalUpdateState then
        pcall(function() CharHL.UpdateState = _G.__originalUpdateState end)
    end
    if coreContainer then
        pcall(function() coreContainer:ClearAllChildren() end)
        pcall(function() coreContainer:Destroy() end)
    end

    for _, drawObj in pairs(skeletonDrawings) do
        SkeletonRenderer.destroy(drawObj)
    end
    skeletonDrawings = {}
end

return ESPManager
