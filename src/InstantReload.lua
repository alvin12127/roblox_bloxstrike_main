-- instant reload
-- Makes the weapon reload animation run so fast that the reload finishes as
-- soon as it starts. Ported from the reference source, kept pcall-guarded all
-- the way through so a missing or renamed animator can never throw.
--
-- How it works:
--   1) the game exposes the equipped item through InventoryController's
--      peekCurrentEquippedForMovement(). That module is required once in a pcall
--      and cached, because requiring it a second time is both slow and able to
--      yield on a missing child.
--   2) the weapon object owns two animation controllers, Viewmodel.Animation
--      and CharacterAnimator. Both expose play(name, ...). Replacing play lets
--      us reach whatever AnimationTrack the game just created, and bumping that
--      track's speed is what actually shortens the reload: the game still runs
--      its own animation timeline, it just completes it almost immediately.
--   3) the poll is 0.1s because the equipped weapon is swapped by the game, not
--      by any event we can subscribe to cheaply, and the object identity is all
--      we need to notice the swap.
--
-- Nothing here touches damage, fire rate or network state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local InstantReload = {
    Initialized = false,
    Connections = {},
    Hooked = {},
    Originals = {}
}

-- Loose enough that a rename on the game side degrades to "feature does
-- nothing" instead of an error every frame.
local InventoryController = nil
pcall(function()
    local controllers = ReplicatedStorage:FindFirstChild("Controllers")
    local moduleScript = controllers and controllers:FindFirstChild("InventoryController")
    if moduleScript then
        InventoryController = require(moduleScript)
    end
end)

-- Animation names the game uses for the parts of a reload. Every entry must be
-- the exact string the game passes to play(), the lookup is case sensitive.
local RELOAD_ANIMS = {
    Reload = true,
    ReloadStart = true,
    ReloadAction = true,
    ReloadEnd = true
}

-- 199 is close to Roblox's practical ceiling for AdjustSpeed while still being
-- accepted by tracks that clamp anything unreasonable.
local RELOAD_SPEED = 199

-- Config defaults. Every read goes through isEnabled() / getters below so a
-- missing Config key can never raise.
local DEFAULT_ENABLED = false
local POLL_INTERVAL = 0.1

local storedConfig = nil
local loopActive = false
local lastWeapon = nil

-- InstantReload.Hooked doubles as the guard against double hooking: an animator
-- already present in it keeps its original play untouched. InstantReload.Originals
-- holds the matching original functions so cleanup() can put everything back.
local reloadHooked = InstantReload.Hooked

local function isEnabled()
    if type(storedConfig) ~= "table" then return DEFAULT_ENABLED end
    local enabled = storedConfig.INSTANT_RELOAD
    if enabled == nil then return DEFAULT_ENABLED end
    return enabled == true
end

-- Reading a possibly missing field off a Roblox Instance throws, so any access
-- to something reached by name goes through here.
local function getField(object, name)
    if object == nil then return nil end

    local ok, value = pcall(function() return object[name] end)
    if ok then return value end
    return nil
end

local function isReloadAnim(name)
    if type(name) ~= "string" then return false end
    return RELOAD_ANIMS[name] == true
end

local function speedUpTrack(track)
    if track == nil then return end

    pcall(function()
        if track.AdjustSpeed then
            track:AdjustSpeed(RELOAD_SPEED)
        end
    end)
end

-- Replace play() on one animation controller. The replacement always calls the
-- original first and hands its result straight back, so from the game's point of
-- view nothing changed; only the returned reload track gets sped up.
local function hookAnimator(animator)
    if animator == nil then return end
    if type(animator) ~= "table" and typeof(animator) ~= "Instance" then return end
    if reloadHooked[animator] then return end

    local okRead, original = pcall(function() return animator.play end)
    if (not okRead) or type(original) ~= "function" then return end

    local okWrite = pcall(function()
        animator.play = function(self, animName, ...)
            local okPlay, track = pcall(original, self, animName, ...)
            if (not okPlay) or track == nil then return nil end

            if isEnabled() and isReloadAnim(animName) then
                speedUpTrack(track)
            end

            return track
        end
    end)

    if not okWrite then return end

    reloadHooked[animator] = true
    InstantReload.Originals[animator] = original
end

-- Viewmodel.Animation drives the first person hands, CharacterAnimator the third
-- person body. Both have to be sped up or the reload ends at different times
-- depending on where the camera is.
local function hookWeapon(weapon)
    if weapon == nil then return end

    local viewmodel = getField(weapon, "Viewmodel")
    local viewmodelAnimation = getField(viewmodel, "Animation")

    hookAnimator(viewmodelAnimation)
    hookAnimator(getField(weapon, "CharacterAnimator"))
end

local function getCurrentWeapon()
    if not InventoryController then return nil end

    local ok, weapon = pcall(function()
        return InventoryController.peekCurrentEquippedForMovement()
    end)

    if ok then return weapon end
    return nil
end

local function pollOnce()
    -- The poll runs whether or not the feature is enabled: the toggle is read at
    -- animation time, so turning it on later takes effect on the next reload
    -- without waiting for the weapon to be re-equipped.
    local weapon = getCurrentWeapon()
    if weapon == lastWeapon then return end

    lastWeapon = weapon
    hookWeapon(weapon)
end

local function startPoll()
    if loopActive then return end
    loopActive = true

    task.spawn(function()
        while loopActive do
            pcall(pollOnce)
            task.wait(POLL_INTERVAL)
        end
    end)
end

-- Respawning rebuilds the viewmodel, so clear the cached object and let the next
-- poll pick up the new one.
local function watchRespawn()
    if not Players then return end

    local ok, charConn = pcall(function()
        return Players.LocalPlayer.CharacterAdded:Connect(function()
            lastWeapon = nil
            task.delay(0.5, function()
                pcall(pollOnce)
            end)
        end)
    end)

    if ok and charConn then
        table.insert(InstantReload.Connections, charConn)
    end
end

local function restoreOriginals()
    for animator, original in pairs(InstantReload.Originals) do
        if type(original) == "function" then
            pcall(function() animator.play = original end)
        end
    end

    InstantReload.Originals = {}
    InstantReload.Hooked = {}
    reloadHooked = InstantReload.Hooked
end

function InstantReload.init(Config)
    if InstantReload.Initialized then return end
    InstantReload.Initialized = true

    storedConfig = Config
    lastWeapon = nil

    pcall(watchRespawn)

    -- first hook straight away rather than waiting for the first poll tick
    hookWeapon(getCurrentWeapon())

    startPoll()
end

function InstantReload.cleanup()
    loopActive = false

    for _, conn in ipairs(InstantReload.Connections) do
        pcall(function() conn:Disconnect() end)
    end
    InstantReload.Connections = {}

    restoreOriginals()

    lastWeapon = nil
    storedConfig = nil
    InstantReload.Initialized = false
end

return InstantReload
