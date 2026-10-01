-- third person camera
-- Uses the approach from the reference source: position the camera directly
-- via CFrame in a BindToRenderStep callback instead of modifying CameraMode
-- or CameraMaxZoomDistance. This avoids interfering with the game's camera
-- system and metatable, which was causing damage-dealing scripts to fail.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local ThirdPerson = {
    Initialized = false,
    StepName = "Bloxstrike_ThirdPerson",
    WasOn = false,
    OrigFov = nil
}

local storedConfig = nil

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = {}

local function isEnabled()
    return storedConfig and storedConfig.THIRDPERSON_ENABLED == true
end

local function currentDistance()
    return math.clamp(tonumber(storedConfig and storedConfig.THIRDPERSON_DISTANCE) or 10, 4, 40)
end

local function currentHeight()
    return tonumber(storedConfig and storedConfig.THIRDPERSON_HEIGHT) or 1.5
end

local function guardAllowed()
    return storedConfig and storedConfig.THIRDPERSON_GUARD ~= false
end

-- Position camera behind the character, raycast for wall collision
local function thirdStep(c)
    local ch = LocalPlayer.Character
    local head = ch and (ch:FindFirstChild("Head") or ch.PrimaryPart)
    if not head then return end

    local rot = c.CFrame - c.CFrame.Position
    local pivot = head.Position + Vector3.new(0, currentHeight(), 0)
    local target = pivot + rot:VectorToWorldSpace(Vector3.new(1.5, 0, currentDistance()))

    -- Wall collision raycast
    if guardAllowed() then
        rayParams.FilterDescendantsInstances = {ch}
        local dir = target - pivot
        local hit = Workspace:Raycast(pivot, dir, rayParams)
        if hit then
            target = hit.Position - dir.Unit * 0.6
        end
    end

    c.CFrame = CFrame.new(target) * rot
end

local function cameraStep()
    local c = Workspace.CurrentCamera
    if not c then return end

    if isEnabled() then
        ThirdPerson.WasOn = true
        pcall(thirdStep, c)
    elseif ThirdPerson.WasOn then
        ThirdPerson.WasOn = false
    end
end

function ThirdPerson.init(Config)
    if ThirdPerson.Initialized then return end
    ThirdPerson.Initialized = true

    storedConfig = Config

    -- Bind after camera priority so our CFrame write wins
    pcall(function()
        RunService:BindToRenderStep(ThirdPerson.StepName, Enum.RenderPriority.Last.Value + 2, function()
            pcall(cameraStep)
        end)
    end)
end

function ThirdPerson.disable()
    ThirdPerson.WasOn = false
end

function ThirdPerson.cleanup()
    pcall(function()
        RunService:UnbindFromRenderStep(ThirdPerson.StepName)
    end)

    ThirdPerson.WasOn = false
    storedConfig = nil
    ThirdPerson.Initialized = false
end

return ThirdPerson