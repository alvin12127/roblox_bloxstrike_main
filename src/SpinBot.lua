-- spin bot and anti aim
-- Rotates the local rig. Applied in a late RenderStep bind (same trick the
-- third person camera uses) because the game drives its character rig
-- through a custom controller that overwrites the root transform every
-- frame. Writing after the camera priority means our rotation survives
-- until the frame is drawn.
--
-- Two extra guards keep the rotation from being fought:
--   * Humanoid.AutoRotate is disabled while active (restored on cleanup)
--   * AssemblyLinearVelocity is preserved so the physics solver does not
--     snap the rig back right after the CFrame write.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

local SpinBot = {
    Initialized = false,
    Connection = nil,
    StepName = "Bloxstrike_SpinBot"
}

local storedConfig = nil
local spinAngle = 0
local lastTime = 0
local autoRotateSaved = nil

local function applyEffects()
    local config = storedConfig
    if not config then return end

    local spinOn = config.SPINBOT_ENABLED == true
    local antiAimOn = config.ANTIAIM_ENABLED == true

    -- Nothing active: restore AutoRotate and bail out early
    if (not spinOn) and (not antiAimOn) then
        if autoRotateSaved ~= nil then
            pcall(function()
                local hum = LocalPlayer.Character
                    and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
                if hum then hum.AutoRotate = autoRotateSaved end
            end)
            autoRotateSaved = nil
        end
        return
    end

    local char = LocalPlayer.Character
    if not char or not char.Parent then return end
    if char:GetAttribute("Dead") == true then return end

    -- Try every plausible root part name. The game may use a custom rig
    -- where the standard HumanoidRootPart is absent.
    local root = char:FindFirstChild("HumanoidRootPart")
        or char:FindFirstChild("UpperTorso")
        or char:FindFirstChild("Torso")
        or char:FindFirstChild("LowerTorso")
        or char.PrimaryPart

    if not root or not root:IsA("BasePart") then
        -- Last resort: any BasePart in the character
        pcall(function()
            for _, p in ipairs(char:GetDescendants()) do
                if p:IsA("BasePart") then
                    root = p
                    break
                end
            end
        end)
    end

    if not root or not root:IsA("BasePart") then return end

    -- Stop the stock controller from fighting our yaw
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        if autoRotateSaved == nil then
            autoRotateSaved = hum.AutoRotate
        end
        if hum.AutoRotate ~= false then
            hum.AutoRotate = false
        end
    end

    local now = os.clock()
    local delta = math.min(math.max(now - lastTime, 0), 0.1)
    lastTime = now

    -- Keep the current position, rebuild rotation
    local pos = root.Position
    local yaw = 0
    local pitch = 0
    local roll = 0

    if spinOn then
        local rpm = config.SPINBOT_RPM or 600
        spinAngle = (spinAngle + delta * (rpm / 60) * (2 * math.pi)) % (2 * math.pi)
        yaw = spinAngle
    end

    if antiAimOn then
        pitch = math.rad(config.ANTIAIM_PITCH or 0)
        -- jitter/random yaw offsets if a yaw base is selected
        local yawBase = config.ANTIAIM_YAW_BASE
        if type(yawBase) == "string" then
            local lower = string.lower(yawBase)
            if lower == "spin" then
                local speed = config.ANTIAIM_SPIN_SPEED or 360
                spinAngle = (spinAngle + delta * (speed / 60) * (2 * math.pi)) % (2 * math.pi)
                yaw = spinAngle
            elseif lower == "jitter" then
                local jitter = config.ANTIAIM_JITTER_OFFSET or 30
                yaw = yaw + math.rad(math.random(-jitter, jitter))
            elseif lower == "random" then
                yaw = yaw + math.rad(math.random(0, 360))
            end
        end
        -- yaw offset slider
        local yawOffset = config.ANTIAIM_YAW_OFFSET
        if type(yawOffset) == "number" then
            yaw = yaw + math.rad(yawOffset)
        end
    end

    -- Preserve velocity so physics does not fight the write
    local vel = root.AssemblyLinearVelocity
    local target = CFrame.new(pos) * CFrame.Angles(pitch, yaw, roll)

    pcall(function()
        root.CFrame = target
    end)

    pcall(function()
        if root.AssemblyLinearVelocity ~= vel then
            root.AssemblyLinearVelocity = vel
        end
    end)
end

function SpinBot.init(Config)
    if SpinBot.Initialized then return end
    SpinBot.Initialized = true

    storedConfig = Config
    lastTime = os.clock()

    -- Use a late RenderStep bind instead of Heartbeat. The game drives its
    -- character rig through its own controller (Classes.Character) which
    -- overwrites the root transform every frame. Binding after the camera
    -- priority is what made the third person camera stick, so the rotation
    -- is applied last and survives until it is drawn.
    pcall(function()
        RunService:BindToRenderStep(SpinBot.StepName, Enum.RenderPriority.Last.Value + 3, function()
            pcall(applyEffects)
        end)
    end)
end

function SpinBot.cleanup()
    -- Unbind the render step (the connection field is no longer used)
    pcall(function()
        RunService:UnbindFromRenderStep(SpinBot.StepName)
    end)

    if SpinBot.Connection then
        pcall(function() SpinBot.Connection:Disconnect() end)
        SpinBot.Connection = nil
    end

    -- Restore AutoRotate
    pcall(function()
        local hum = LocalPlayer.Character
            and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
        if hum and autoRotateSaved ~= nil then
            hum.AutoRotate = autoRotateSaved
        end
    end)
    autoRotateSaved = nil

    spinAngle = 0
    storedConfig = nil
    SpinBot.Initialized = false
end

return SpinBot