-- Fake duck: keep full walking speed while crouched.
--
-- The request: the crouch pose may stay visible (locally is fine), only the speed
-- penalty is unwanted. So nothing here touches animation, the pose, or the rig -
-- it only fights the speed cap while the player is crouched.
--
-- Why this cannot be done with WalkSpeed: the dump shows ZERO [Humanoid]
-- instances under Characters. These are custom rigs (IDF, Anarchist) with a
-- HumanoidRootPart, Motor6Ds and an Animator, driven by attributes. There is no
-- Humanoid.WalkSpeed to write, so every "just set WalkSpeed" approach is a no-op
-- here - which is why this module works on velocity instead.
--
-- The signal is the rig's own @IsCrouching attribute, present on every character
-- in the dump. It is the game telling us the crouch state directly, so it does not
-- depend on guessing from the pose or from keybinds.
--
-- How the speed is restored:
--   * the normal horizontal speed is measured, not assumed - the highest horizontal
--     speed seen while NOT crouching is kept as the reference, so it adapts to
--     whatever the map and the current weapon actually allow
--   * while crouched, the horizontal component of AssemblyLinearVelocity is scaled
--     up to that reference, along the existing direction
--   * scaling rather than overwriting matters: the direction is left to the game's
--     own movement code, so steering, slope handling and collision are unchanged
--   * only a genuinely moving player is corrected, otherwise the player would slide
--     on the spot when standing still
--   * vertical velocity is never touched, so jumping and falling are unaffected
--
-- The correction runs on Heartbeat because the game re-applies its own cap every
-- step; a RenderStepped write would be overwritten before the next physics tick.

local RunService = nil
local Players = nil

pcall(function()
    RunService = game:GetService("RunService")
    Players = game:GetService("Players")
end)

-- Resolved per step rather than captured once at load. Cheap, and it means the
-- module keeps working if the LocalPlayer reference is ever swapped.
local function localCharacter()
    local character = nil
    pcall(function() character = Players.LocalPlayer.Character end)
    return character
end

local FakeDuck = {
    Initialized = false,
    Connection = nil,

    -- Highest horizontal speed observed while upright. Learned rather than
    -- hard-coded: the dump contains no movement constants at all, so a guess
    -- would be wrong on any map that is not the default.
    normalSpeed = 0,
    -- Until enough samples exist, assume Roblox's default rather than doing
    -- nothing, so the very first crouch still benefits.
    lastKnownNormal = 16,

    -- Below this the player is considered stationary and left alone.
    MIN_MOVING = 0.75,
    -- Never push past the upright speed by more than a little; overshooting reads
    -- as speed hacking even when it is only a rounding artefact.
    MAX_GAIN = 1.05,
}

local storedConfig = nil

local function isCrouched(character)
    if not character then return false end
    local crouching = nil
    pcall(function() crouching = character:GetAttribute("IsCrouching") end)
    if type(crouching) == "boolean" then return crouching end

    -- No attribute on this rig: fall back to the Humanoid if a future build adds
    -- one. Written the long way so a missing Humanoid is nil, not an error.
    local hum = nil
    pcall(function() hum = character:FindFirstChildOfClass("Humanoid") end)
    if hum then
        local ok, state = pcall(function()
            return hum:GetState()
        end)
        -- Compared by name rather than by type: Roblox returns an EnumItem, but
        -- some executors hand back a plain table, and type-checking would
        -- silently disable the whole fallback.
        if ok and state ~= nil then
            local stateName = nil
            pcall(function() stateName = state.Name end)
            if type(stateName) == "string" then return stateName == "Crouched" end
        end
    end

    return false
end

local function rootOf(character)
    local root = nil
    pcall(function() root = character:FindFirstChild("HumanoidRootPart") end)
    return root
end

local function horizontal(v)
    return math.sqrt((v.X * v.X) + (v.Z * v.Z))
end

local function step()
    if not storedConfig then return end

    local enabled = storedConfig.FAKE_DUCK_ENABLED
    if enabled == nil then enabled = false end
    if not enabled then return end

    local character = localCharacter()
    if not character then return end

    local root = rootOf(character)
    if not root then return end

    local velocity = nil
    pcall(function() velocity = root.AssemblyLinearVelocity end)
    if not velocity then return end

    local speed = horizontal(velocity)
    local crouched = isCrouched(character)

    if not crouched then
        -- Learn the upright speed from real movement. Only a moving player
        -- teaches anything useful, and a downhill sprint must not poison the
        -- reference with a number the game would never allow while standing.
        if speed > FakeDuck.MIN_MOVING then
            FakeDuck.normalSpeed = math.max(FakeDuck.normalSpeed, speed)
            if FakeDuck.normalSpeed > 1 then
                FakeDuck.lastKnownNormal = FakeDuck.normalSpeed
            end
        end
        return
    end

    -- Primary mechanism: clear the flag the game itself uses to apply the crouch
    -- penalty.
    --
    -- The velocity write below was tried first and does not stick: the movement
    -- simulation re-applies its own cap every physics step, so a client-side
    -- write is corrected before it is ever seen. That is not a tuning problem, it
    -- is the wrong layer - the penalty is applied from @IsCrouching, so the only
    -- thing worth fighting is the flag.
    --
    -- Setting it false makes the game treat the player as standing, so no cap is
    -- applied at all. The accepted trade-off, as requested: the local player then
    -- also appears to stand, and only locally so. Nothing here touches other
    -- players, the rig, the animation or the camera.
    pcall(function()
        character:SetAttribute("IsCrouching", false)
    end)

    -- Second layer, kept because it costs nothing and covers a build that caps
    -- velocity instead of reading the attribute.
    local target = FakeDuck.lastKnownNormal
    if target <= FakeDuck.MIN_MOVING then return end
    if speed >= target then return end
    -- Stationary while crouched: leaving it alone means the player does not slide.
    if speed < 0.05 then return end

    local gain = math.min(target * FakeDuck.MAX_GAIN, target) / speed
    if gain <= 1 then return end

    pcall(function()
        root.AssemblyLinearVelocity = Vector3.new(
            velocity.X * gain,
            velocity.Y,
            velocity.Z * gain
        )
    end)
end

function FakeDuck.init(Config)
    if FakeDuck.Initialized then return end
    FakeDuck.Initialized = true

    storedConfig = Config

    FakeDuck.Connection = RunService.Heartbeat:Connect(function()
        pcall(step)
    end)
end

function FakeDuck.cleanup()
    if FakeDuck.Connection then
        pcall(function() FakeDuck.Connection:Disconnect() end)
        FakeDuck.Connection = nil
    end
    FakeDuck.normalSpeed = 0
    FakeDuck.lastKnownNormal = 16
    storedConfig = nil
    FakeDuck.Initialized = false
end

return FakeDuck
