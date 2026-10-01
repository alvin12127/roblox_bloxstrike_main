-- bunny hop (auto jump + auto strafe)
--
-- MovementV2 samples keyboard intent through CharacterClass.SampleInput, so the
-- jump/strafe buttons have to be written into the sample table that function
-- returns - nothing else reaches the movement simulation. Heartbeat drives the
-- state machine here: it decides grounded vs airborne, picks the strafe side and
-- raises the jump request, and SampleInput ships that decision to the game on the
-- very next sample. The humanoid/velocity path is only a fallback for when those
-- game modules are missing (or were moved by an update).

local RunService = nil
local UserInputService = nil
local ReplicatedStorage = nil
local Players = nil
local Workspace = nil

pcall(function()
    RunService = game:GetService("RunService")
    UserInputService = game:GetService("UserInputService")
    ReplicatedStorage = game:GetService("ReplicatedStorage")
    Players = game:GetService("Players")
    Workspace = game:GetService("Workspace")
end)

local CharacterClass = nil
local Buttons = nil
local LocalPlayer = nil

pcall(function()
    if not ReplicatedStorage then return end
    local okChar, charModule = pcall(function()
        return require(ReplicatedStorage.Classes.Character)
    end)
    if okChar and type(charModule) == "table" then
        CharacterClass = charModule
    end

    local okButtons, buttonsModule = pcall(function()
        return require(ReplicatedStorage.MovementV2.Buttons)
    end)
    if okButtons and type(buttonsModule) == "table" then
        Buttons = buttonsModule
    end
end)

pcall(function()
    if Players then
        LocalPlayer = Players.LocalPlayer
    end
end)

local Bhop = {
    Initialized = false,
    Connections = {},
    IsHoldingSpace = false,
    OnGround = true,
    WantsJump = false,
    StrafeDirection = 1
}

-- cached config, filled by Bhop.init
local storedConfig = nil
local originalSampleInput = nil

-- seconds left before the strafe side may flip again (stops ground jitter spam)
local strafeFlipTimer = 0

-- hard cap so a bad config value can never launch the player across the map
local MAX_HORIZONTAL_SPEED = 220

-- keys that count as "the player is trying to move"
local MOVE_KEY_CODES = {
    Enum.KeyCode.W,
    Enum.KeyCode.A,
    Enum.KeyCode.S,
    Enum.KeyCode.D,
    Enum.KeyCode.Up,
    Enum.KeyCode.Down,
    Enum.KeyCode.Left,
    Enum.KeyCode.Right
}

-- every number read from the config funnels through here so a nil/garbage value
-- falls back to the documented default instead of poisoning the math
local function getConfigNumber(key, fallback)
    if type(storedConfig) ~= "table" then return fallback end

    local value = tonumber(storedConfig[key])
    if type(value) ~= "number" then return fallback end
    if value ~= value then return fallback end
    if value == math.huge or value == -math.huge then return fallback end

    return value
end

local function getConfigBool(key, fallback)
    if type(storedConfig) ~= "table" then return fallback end

    local value = storedConfig[key]
    if type(value) == "boolean" then return value end

    return fallback
end

local function isSpaceHeld()
    local ok, down = pcall(function()
        return UserInputService:IsKeyDown(Enum.KeyCode.Space)
    end)
    if ok and down == true then return true end

    return Bhop.IsHoldingSpace == true
end

local function hasMoveInput()
    local ok, moving = pcall(function()
        for _, keyCode in ipairs(MOVE_KEY_CODES) do
            if UserInputService:IsKeyDown(keyCode) then
                return true
            end
        end
        return false
    end)

    return (ok == true) and (moving == true)
end

local function getCharacter()
    if not LocalPlayer then return nil end

    local ok, character = pcall(function()
        return LocalPlayer.Character
    end)
    if not ok or not character then return nil end

    return character
end

local function getHumanoid(character)
    if not character then return nil end

    local ok, humanoid = pcall(function()
        local found = character:FindFirstChildOfClass("Humanoid")
        if found and found:IsA("Humanoid") then return found end
        return nil
    end)
    if ok then return humanoid end

    return nil
end

local function getRootPart(character)
    if not character then return nil end

    local ok, root = pcall(function()
        local found = character:FindFirstChild("HumanoidRootPart")
        if not found or not found:IsA("BasePart") then
            found = character:FindFirstChild("UpperTorso")
        end
        if not found or not found:IsA("BasePart") then
            found = character:FindFirstChild("Torso")
        end
        if found and found:IsA("BasePart") then return found end
        return nil
    end)
    if ok then return root end

    return nil
end

local function isAlive(character, humanoid)
    if not character then return false end
    if character.Parent == nil then return false end

    local deadFlag = false
    pcall(function()
        deadFlag = (character:GetAttribute("Dead") == true)
    end)
    if deadFlag then return false end

    if humanoid then
        local okHealth, health = pcall(function() return humanoid.Health end)
        if okHealth and type(health) == "number" and health <= 0 then
            return false
        end
    end

    return true
end

-- grounded test: humanoid state first, short downward raycast as the fallback
-- for rigs whose humanoid is not authoritative
local function isOnGround(character, humanoid, root)
    if humanoid then
        local okState, state = pcall(function() return humanoid:GetState() end)
        if okState and state then
            if state == Enum.HumanoidStateType.Freefall then return false end
            if state == Enum.HumanoidStateType.Jumping then return false end
        end

        local okFloor, floorMaterial = pcall(function() return humanoid.FloorMaterial end)
        if okFloor and floorMaterial and floorMaterial ~= Enum.Material.Air then
            return true
        end
    end

    if not root then return false end

    local okHit, hit = pcall(function()
        local params = RaycastParams.new()
        params.FilterDescendantsInstances = { character }
        params.FilterType = Enum.RaycastFilterType.Exclude

        local distance = 0
        local okSize, size = pcall(function() return root.Size end)
        if okSize and type(size) == "userdata" then
            distance = size.Y * 0.5 + 0.6
        else
            distance = 3.5
        end

        return Workspace:Raycast(root.Position, Vector3.new(0, -distance, 0), params)
    end)
    if okHit then
        return hit ~= nil
    end

    return false
end

local function getHorizontalSpeed(root)
    if not root then return 0 end

    local ok, speed = pcall(function()
        local velocity = root.AssemblyLinearVelocity
        return math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)
    end)
    if ok and type(speed) == "number" and speed == speed then
        return speed
    end

    return 0
end

-- lateral nudge along the camera's right vector, vertical velocity is preserved
-- so the jump arc is never flattened
local function applyStrafeForce(root, dt)
    if not root then return end

    local force = getConfigNumber("BHOP_STRAFE_FORCE", 2)
    if force <= 0 then return end

    pcall(function()
        local camera = Workspace and Workspace.CurrentCamera
        if not camera then return end

        local right = camera.CFrame.RightVector
        local lateral = Vector3.new(right.X, 0, right.Z)
        if lateral.Magnitude < 0.001 then return end

        local velocity = root.AssemblyLinearVelocity
        local accel = force * dt * 60
        local added = Vector3.new(
            velocity.X + lateral.Unit.X * accel * Bhop.StrafeDirection,
            velocity.Y,
            velocity.Z + lateral.Unit.Z * accel * Bhop.StrafeDirection
        )

        local horizontal = Vector3.new(added.X, 0, added.Z)
        if horizontal.Magnitude > MAX_HORIZONTAL_SPEED then
            local clamped = horizontal.Unit * MAX_HORIZONTAL_SPEED
            added = Vector3.new(clamped.X, velocity.Y, clamped.Z)
        end

        root.AssemblyLinearVelocity = added
    end)
end

-- fallback jump for rigs that still use the stock humanoid controller
local function jumpWithHumanoid(humanoid)
    if not humanoid then return end

    pcall(function()
        humanoid.Jump = true
    end)
end

-- writes the current bhop decision into a movement sample, in place
local function applyButtonsToSample(sample)
    if type(sample) ~= "table" then return end
    if type(Buttons) ~= "table" then return end
    if type(Buttons.with) ~= "function" then return end

    pcall(function()
        local buttons = sample.Buttons

        local wantsJump = (Bhop.WantsJump == true)
        if Buttons.Jump ~= nil then
            buttons = Buttons.with(buttons, Buttons.Jump, wantsJump)
        end

        -- strafing is an air move, holding jump wins while grounded
        if (not wantsJump) and (getConfigBool("BHOP_AUTO_STRAFE", true) ~= false) then
            if Bhop.StrafeDirection < 0 and Buttons.Left ~= nil then
                buttons = Buttons.with(buttons, Buttons.Left, true)
                if Buttons.Right ~= nil then
                    buttons = Buttons.with(buttons, Buttons.Right, false)
                end
            elseif Bhop.StrafeDirection > 0 and Buttons.Right ~= nil then
                buttons = Buttons.with(buttons, Buttons.Right, true)
                if Buttons.Left ~= nil then
                    buttons = Buttons.with(buttons, Buttons.Left, false)
                end
            end
        end

        sample.Buttons = buttons
    end)
end

local function hookSampleInput()
    if type(CharacterClass) ~= "table" then return end

    local hasSampleInput = false
    pcall(function()
        hasSampleInput = (type(CharacterClass.SampleInput) == "function")
    end)
    if not hasSampleInput then return end

    if type(_G.__originalSampleInput) ~= "function" then
        _G.__originalSampleInput = CharacterClass.SampleInput
    end
    originalSampleInput = _G.__originalSampleInput
    if type(originalSampleInput) ~= "function" then return end

    pcall(function()
        CharacterClass.SampleInput = function(self, p2)
            local okSample, sample = pcall(originalSampleInput, self, p2)
            if not okSample or sample == nil then return sample end

            pcall(applyButtonsToSample, sample)

            return sample
        end
    end)
end

local function restoreSampleInput()
    if type(CharacterClass) ~= "table" then
        originalSampleInput = nil
        _G.__originalSampleInput = nil
        return
    end

    if type(originalSampleInput) ~= "function" then
        originalSampleInput = _G.__originalSampleInput
    end

    if type(originalSampleInput) == "function" then
        pcall(function()
            CharacterClass.SampleInput = originalSampleInput
        end)
    end

    originalSampleInput = nil
    _G.__originalSampleInput = nil
end

-- one frame of the bhop state machine
local function update(dt)
    if type(storedConfig) ~= "table" then return end
    if getConfigBool("BHOP_ENABLED", true) == false then
        Bhop.WantsJump = false
        return
    end

    local step = tonumber(dt)
    if type(step) ~= "number" or step ~= step or step <= 0 then
        step = 1 / 60
    end
    if step > 0.1 then step = 0.1 end

    if strafeFlipTimer > 0 then
        strafeFlipTimer = strafeFlipTimer - step
    end

    local character = getCharacter()
    if not character then
        Bhop.WantsJump = false
        return
    end

    local humanoid = getHumanoid(character)
    local root = getRootPart(character)
    if not root or not isAlive(character, humanoid) then
        Bhop.WantsJump = false
        return
    end

    -- "Legit" waits for the player to hold space, "Rage" hops on its own
    local mode = storedConfig.BHOP_MODE
    if type(mode) ~= "string" then mode = "Legit" end
    local isRage = (string.lower(mode) == "rage")

    if (not isRage) and (not isSpaceHeld()) then
        Bhop.WantsJump = false
        return
    end

    local minSpeed = getConfigNumber("BHOP_MIN_SPEED", 10)
    local speed = getHorizontalSpeed(root)

    -- below the floor speed the hop is dead anyway, unless the player is still
    -- feeding movement input and can rebuild it
    if speed < minSpeed and (not hasMoveInput()) then
        Bhop.WantsJump = false
        return
    end

    local grounded = isOnGround(character, humanoid, root)
    Bhop.OnGround = grounded

    if grounded then
        -- classic autostrafe: swap the strafe side on every landing
        if strafeFlipTimer <= 0 then
            Bhop.StrafeDirection = -Bhop.StrafeDirection
            strafeFlipTimer = 0.08
        end

        if getConfigBool("BHOP_AUTO_JUMP", true) ~= false then
            Bhop.WantsJump = true
            jumpWithHumanoid(humanoid)
        else
            Bhop.WantsJump = false
        end
    else
        -- released mid-air so the next landing reads as a fresh press
        Bhop.WantsJump = false

        if getConfigBool("BHOP_AUTO_STRAFE", true) ~= false then
            applyStrafeForce(root, step)
        end
    end
end

local function trackSpaceKey()
    if not UserInputService then return end

    pcall(function()
        local beganConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
            if input.KeyCode == Enum.KeyCode.Space then
                Bhop.IsHoldingSpace = true
            end
        end)
        table.insert(Bhop.Connections, beganConn)

        local endedConn = UserInputService.InputEnded:Connect(function(input, gameProcessed)
            if input.KeyCode == Enum.KeyCode.Space then
                Bhop.IsHoldingSpace = false
            end
        end)
        table.insert(Bhop.Connections, endedConn)
    end)
end

function Bhop.init(Config)
    if Bhop.Initialized then return end
    Bhop.Initialized = true

    storedConfig = Config
    strafeFlipTimer = 0

    hookSampleInput()
    trackSpaceKey()

    if RunService then
        pcall(function()
            local heartbeatConn = RunService.Heartbeat:Connect(function(step)
                pcall(update, step)
            end)
            table.insert(Bhop.Connections, heartbeatConn)
        end)
    end
end

function Bhop.cleanup()
    for _, connection in ipairs(Bhop.Connections) do
        pcall(function() connection:Disconnect() end)
    end
    Bhop.Connections = {}

    restoreSampleInput()

    Bhop.WantsJump = false
    Bhop.IsHoldingSpace = false
    Bhop.OnGround = true
    Bhop.StrafeDirection = 1
    strafeFlipTimer = 0
    storedConfig = nil
    Bhop.Initialized = false
end

return Bhop
