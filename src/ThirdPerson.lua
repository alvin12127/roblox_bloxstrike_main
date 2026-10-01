-- third person camera
-- The camera keeps its own rotation, so mouse look stays untouched, and its
-- position is recomputed from the character root every frame. That makes the
-- offset impossible to accumulate frame over frame.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local ThirdPerson = {
    Initialized = false,
    Connection = nil
}

local storedConfig = nil

local function apply()
    local config = storedConfig
    if not config or (config.THIRDPERSON_ENABLED ~= true) then return end

    local char = LocalPlayer.Character
    if not char or not char.Parent then return end
    if char:GetAttribute("Dead") == true then return end

    local root = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("UpperTorso")
    if not root or not root:IsA("BasePart") then return end

    local head = char:FindFirstChild("Head")
    local headOffsetY = head and (head.Position.Y - root.Position.Y) or 0

    local ok, rotation = pcall(function() return Camera.CFrame.Rotation end)
    if not ok or not rotation then return end

    local distance = tonumber(config.THIRDPERSON_DISTANCE) or 9
    local height = tonumber(config.THIRDPERSON_HEIGHT) or 0

    local anchor = root.Position + Vector3.new(0, headOffsetY + height, 0)
    local position = anchor + (rotation.LookVector * -distance)

    Camera.CFrame = CFrame.new(position) * rotation
end

function ThirdPerson.init(Config)
    if ThirdPerson.Initialized then return end
    ThirdPerson.Initialized = true

    storedConfig = Config

    ThirdPerson.Connection = RunService.RenderStepped:Connect(function()
        pcall(apply)
    end)
end

function ThirdPerson.cleanup()
    if ThirdPerson.Connection then
        pcall(function() ThirdPerson.Connection:Disconnect() end)
        ThirdPerson.Connection = nil
    end

    storedConfig = nil
    ThirdPerson.Initialized = false
end

return ThirdPerson
