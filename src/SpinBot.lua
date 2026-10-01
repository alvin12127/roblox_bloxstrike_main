-- spin bot and anti aim
-- The rig is rotated on Heartbeat, not RenderStepped. Roblox samples the network
-- owner's part transforms after the physics step, so a rotation written during
-- RenderStepped only ever shows up on our own screen and is never replicated to
-- the server or to other players. Heartbeat runs directly after physics, which is
-- the window where the change still makes it into the replicated transform.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

local SpinBot = {
    Initialized = false,
    Connection = nil
}

local storedConfig = nil
local spinAngle = 0
local lastTime = 0

local function applyEffects()
    local config = storedConfig
    if not config then return end

    -- Default to enabled if not explicitly disabled
    local spinOn = config.SPINBOT_ENABLED
    if spinOn == nil then spinOn = true end
    
    local antiAimOn = config.ANTIAIM_ENABLED
    if antiAimOn == nil then antiAimOn = true end

    if (not spinOn) and (not antiAimOn) then return end

    local char = LocalPlayer.Character
    if not char or not char.Parent then return end
    if char:GetAttribute("Dead") == true then return end

    local root = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("UpperTorso")
    if not root or not root:IsA("BasePart") then return end

    local now = os.clock()
    local delta = math.min(math.max(now - lastTime, 0), 0.1)
    lastTime = now

    local targetCFrame = root.CFrame
    local changed = false

    if spinOn then
        local rpm = config.SPINBOT_RPM or 600
        spinAngle = (spinAngle + delta * (rpm / 60) * (2 * math.pi)) % (2 * math.pi)
        targetCFrame = CFrame.new(root.Position) * CFrame.Angles(0, spinAngle, 0)
        changed = true
    end

    if antiAimOn then
        local pitch = config.ANTIAIM_PITCH or 0
        if pitch ~= 0 then
            targetCFrame = targetCFrame * CFrame.Angles(math.rad(pitch), 0, 0)
            changed = true
        end
    end

    -- always write when changed is true, CFrame comparison can be unreliable
    if changed then
        pcall(function()
            root.CFrame = targetCFrame
        end)
    end
end

function SpinBot.init(Config)
    if SpinBot.Initialized then return end
    SpinBot.Initialized = true

    storedConfig = Config
    lastTime = os.clock()

    -- Heartbeat is what makes the rotation replicate, see the note at the top
    SpinBot.Connection = RunService.Heartbeat:Connect(function()
        pcall(applyEffects)
    end)
end

function SpinBot.cleanup()
    if SpinBot.Connection then
        pcall(function() SpinBot.Connection:Disconnect() end)
        SpinBot.Connection = nil
    end

    if storedConfig and storedConfig.SPINBOT_ENABLED == true then
        local char = LocalPlayer.Character
        local root = char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("UpperTorso"))
        if root then
            pcall(function()
                root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, 0, 0)
            end)
        end
    end

    spinAngle = 0
    storedConfig = nil
    SpinBot.Initialized = false
end

return SpinBot
