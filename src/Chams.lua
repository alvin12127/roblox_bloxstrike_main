-- @Discord_alvin6974. / Bloxstrike / v2.5
-- Chams: colours enemy characters with a Highlight instance so they stay
-- visible through walls.
--
-- The Highlight for every player is created once and reused (Chams.Pool is
-- keyed by player Name). The render loop only rewrites the colour and
-- transparency values, so nothing is instanced per frame.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local Chams = {
    Initialized = false,
    Connections = {},
    Pool = {}
}

-- Every piece of state is declared up front: this module follows the project
-- rule that no local may be referenced before it is declared.
local storedConfig = nil

-- Utils is optional. It is either handed to init() as a second argument or
-- picked up from the module registry the loader already keeps around.
local Utils = nil

local PRIMARY_KEYS = { "CHAMS_COLOR", "CHAMS_PRIMARY_COLOR" }
local SECONDARY_KEYS = { "CHAMS_COLOR_SECONDARY", "CHAMS_SECONDARY_COLOR" }

local DEFAULT_PRIMARY = Color3.fromRGB(255, 60, 60)
local DEFAULT_SECONDARY = Color3.fromRGB(60, 200, 255)

-- config readers ------------------------------------------------------------
-- Every read goes through these helpers so a missing, renamed or wrongly typed
-- config key can never abort the render loop.

local function cfgValue(name)
    if storedConfig == nil then return nil end

    local ok, value = pcall(function()
        return storedConfig[name]
    end)

    if ok then return value end
    return nil
end

local function cfgBool(name, default)
    local value = cfgValue(name)
    if type(value) == "boolean" then return value end
    return default
end

local function cfgNumber(name, default)
    local value = tonumber(cfgValue(name))
    if value == nil then return default end
    if value ~= value then return default end -- NaN guard
    return value
end

local function cfgString(name, default)
    local value = cfgValue(name)
    if type(value) == "string" then return string.lower(value) end
    return default
end

local function cfgColor(names, default)
    for _, name in ipairs(names) do
        local value = cfgValue(name)

        if type(value) == "userdata" then
            return value
        elseif type(value) == "table" and value.R and value.G and value.B then
            local ok, built = pcall(function()
                return Color3.new(tonumber(value.R) or 1, tonumber(value.G) or 1, tonumber(value.B) or 1)
            end)
            if ok and built then return built end
        end
    end

    return default
end

-- math helpers --------------------------------------------------------------

local function clamp01(value)
    value = tonumber(value) or 0
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

local function lerpColor(from, to, t)
    t = clamp01(t)
    return Color3.new(
        from.R + (to.R - from.R) * t,
        from.G + (to.G - from.G) * t,
        from.B + (to.B - from.B) * t
    )
end

-- instance helpers ----------------------------------------------------------

local function isAliveInstance(instance)
    if not instance then return false end

    local ok, parent = pcall(function()
        return instance.Parent
    end)

    return ok and parent ~= nil
end

local function getDistance(char)
    local camera = nil
    pcall(function()
        camera = Workspace.CurrentCamera
    end)

    if not camera then return nil end

    local anchor = char:FindFirstChild("Head")
        or char:FindFirstChild("HumanoidRootPart")
        or char:FindFirstChild("UpperTorso")

    if not anchor or not anchor:IsA("BasePart") then return nil end

    local ok, distance = pcall(function()
        return (camera.CFrame.Position - anchor.Position).Magnitude
    end)

    if ok and type(distance) == "number" then return distance end
    return nil
end

-- Returns the colour and both transparency values for one character.
-- Order of precedence: the style picks the base values, the mode then clamps
-- them to what is actually visible (fill only / outline only / both).
local function computeStyle(char)
    local fill = clamp01(cfgNumber("CHAMS_FILL_TRANSPARENCY", 0.5))
    local outline = clamp01(cfgNumber("CHAMS_OUTLINE_TRANSPARENCY", 0.8))

    local mode = cfgString("CHAMS_MODE", "both")
    local style = cfgString("CHAMS_STYLE", "solid")

    local primary = cfgColor(PRIMARY_KEYS, DEFAULT_PRIMARY)
    local secondary = cfgColor(SECONDARY_KEYS, DEFAULT_SECONDARY)

    local fillTransparency = fill
    local outlineTransparency = outline

    if mode == "fill" then
        fillTransparency = fill
        outlineTransparency = 1
    elseif mode == "outline" then
        fillTransparency = 1
        outlineTransparency = outline
    end

    local color = primary
    local outlineColor = primary

    if style == "pulse" then
        local speed = cfgNumber("CHAMS_PULSE_SPEED", 3)
        local oscillation = 0.5 + 0.5 * math.sin(tick() * speed)

        if mode == "outline" then
            outlineTransparency = clamp01(outlineTransparency * (0.3 + 0.7 * oscillation))
        else
            fillTransparency = clamp01(fillTransparency * (0.3 + 0.7 * oscillation))
        end
    elseif style == "rainbow" then
        local speed = cfgNumber("CHAMS_GRADIENT_SPEED", 2)
        local hue = (tick() * speed) % 1
        local built, builtColor = pcall(function()
            return Color3.fromHSV(hue, 1, 1)
        end)

        if built and builtColor then
            color = builtColor
            outlineColor = builtColor
        end
    elseif style == "gradient" then
        local speed = cfgNumber("CHAMS_GRADIENT_SPEED", 2)
        local blend = 0.5 + 0.5 * math.sin(tick() * speed)
        local mixed = lerpColor(primary, secondary, blend)

        color = mixed
        outlineColor = mixed
    elseif style == "wireframe" then
        -- Only the shell survives, the body is fully see-through.
        fillTransparency = 1
        outlineTransparency = outline
        color = primary
        outlineColor = secondary
    elseif style == "distance" then
        local near = cfgNumber("CHAMS_DISTANCE_NEAR", 100)
        local far = cfgNumber("CHAMS_DISTANCE_FAR", 1500)
        local distance = getDistance(char)

        if distance then
            local blend = clamp01((distance - near) / math.max(far - near, 1))
            local mixed = lerpColor(primary, secondary, blend)

            color = mixed
            outlineColor = mixed
        end
    end

    return color, outlineColor, fillTransparency, outlineTransparency
end

-- highlight pool ------------------------------------------------------------

local function ensureHighlight(name, char)
    local existing = Chams.Pool[name]

    if existing and isAliveInstance(existing) then
        local ok, parent = pcall(function()
            return existing.Parent
        end)

        if ok and parent == char then
            return existing
        end

        -- Respawn: the old model is gone, move the Highlight onto the new one.
        local okMove = pcall(function()
            existing.Parent = char
        end)

        if okMove then return existing end

        pcall(function()
            existing:Destroy()
        end)
        Chams.Pool[name] = nil
    end

    local okNew, created = pcall(function()
        local highlight = Instance.new("Highlight")
        highlight.Name = "AG_Chams"
        highlight.Parent = char
        return highlight
    end)

    if not okNew or not created then return nil end

    Chams.Pool[name] = created
    return created
end

local function releaseHighlight(name)
    local existing = Chams.Pool[name]

    if existing then
        pcall(function()
            existing:Destroy()
        end)
    end

    Chams.Pool[name] = nil
end

-- target validation ---------------------------------------------------------

local function resolveCharacter(player)
    -- Try player.Character first (most reliable)
    local okChar, char = pcall(function()
        local direct = player.Character
        if direct and direct:IsA("Model") and direct:GetAttribute("Dead") ~= true then
            return direct
        end
        return nil
    end)

    if okChar and char then return char end

    -- Fallback: the game keeps every rig under Workspace.Characters, named
    -- after its player.
    okChar, char = pcall(function()
        local charsFolder = Workspace:FindFirstChild("Characters")
        if charsFolder then
            local found = charsFolder:FindFirstChild(player.Name)
            if found and found:IsA("Model") and found:GetAttribute("Dead") ~= true then
                return found
            end
        end
        return nil
    end)

    if okChar and char then return char end

    -- Last resort: Utils
    if Utils and type(Utils.getAliveCharacter) == "function" then
        local ok, utilsChar = pcall(function()
            return Utils.getAliveCharacter(player)
        end)
        if ok and utilsChar then return utilsChar end
    end

    return nil
end

local function getHealth(char)
    if Utils and type(Utils.getCharacterHealth) == "function" then
        local ok, health = pcall(function()
            return Utils.getCharacterHealth(char)
        end)

        if ok and type(health) == "number" then return health end
    end

    local okHealth, health = pcall(function()
        local humanoid = char:FindFirstChildOfClass("Humanoid")
        if humanoid then return humanoid.Health end
        return tonumber(char:GetAttribute("Health"))
    end)

    if okHealth and type(health) == "number" then return health end
    return 0
end

local function isEnemyPlayer(player, char)
    if Utils and type(Utils.isEnemy) == "function" then
        local ok, enemy = pcall(function()
            return Utils.isEnemy(player, char)
        end)

        if ok and type(enemy) == "boolean" then return enemy end
    end

    -- No Utils available: fall back to comparing the Team attribute.
    local okTeam, enemy = pcall(function()
        local myTeam = LocalPlayer and (LocalPlayer:GetAttribute("Team") or LocalPlayer:GetAttribute("TeamName")) or nil
        local theirTeam = player:GetAttribute("Team")
            or player:GetAttribute("TeamName")
            or char:GetAttribute("Team")
            or char:GetAttribute("TeamName")

        if not theirTeam then return false end
        if not myTeam then return true end
        return myTeam ~= theirTeam
    end)

    if okTeam and type(enemy) == "boolean" then return enemy end
    return false
end

local function isValidTarget(player, char)
    if not player or not char then return false end
    if player == LocalPlayer then return false end

    local okCheck, valid = pcall(function()
        if char:GetAttribute("Dead") == true then return false end
        if getHealth(char) <= 0 then return false end
        return isEnemyPlayer(player, char)
    end)

    return okCheck and valid == true
end

-- rendering -----------------------------------------------------------------

local function applyHighlight(highlight, char)
    local color, outlineColor, fillTransparency, outlineTransparency = computeStyle(char)

    local throughWalls = cfgBool("CHAMS_THROUGH_WALLS", false)

    pcall(function()
        highlight.FillColor = color
        highlight.OutlineColor = outlineColor
        highlight.FillTransparency = fillTransparency
        highlight.OutlineTransparency = outlineTransparency
        highlight.DepthMode = throughWalls
            and Enum.HighlightDepthMode.AlwaysOnTop
            or Enum.HighlightDepthMode.Occluded
        highlight.Enabled = true
    end)
end

local function updateCharacter(player)
    local char = resolveCharacter(player)

    if not isValidTarget(player, char) then return false end

    local highlight = ensureHighlight(player.Name, char)
    if not highlight then return false end

    applyHighlight(highlight, char)
    return true
end

local function update()
    local enabled = cfgBool("CHAMS_ENABLED", false)
    local seen = {}

    if enabled then
        local okPlayers, playerList = pcall(function()
            return Players:GetPlayers()
        end)

        if okPlayers and type(playerList) == "table" then
            for _, player in ipairs(playerList) do
                local okPlayer, visible = pcall(function()
                    return updateCharacter(player)
                end)

                if okPlayer and visible then
                    seen[player.Name] = true
                end
            end
        end
    end

    -- Retire every Highlight whose owner is off screen, dead, gone or friendly.
    local stale = {}

    for name in pairs(Chams.Pool) do
        if not seen[name] then
            stale[#stale + 1] = name
        end
    end

    for _, name in ipairs(stale) do
        releaseHighlight(name)
    end
end

local function resolveUtils(utilsModule)
    if type(utilsModule) == "table" then return utilsModule end

    local okRegistry, registry = pcall(function()
        return _G.__BloxstrikeModules
    end)

    if not okRegistry or type(registry) ~= "table" then return nil end

    local factory = registry["Utils"]
    if type(factory) ~= "function" then return nil end

    local okBuilt, built = pcall(factory)
    if okBuilt and type(built) == "table" then return built end

    return nil
end

-- public api ----------------------------------------------------------------

function Chams.init(Config, utilsModule)
    if Chams.Initialized then return end
    Chams.Initialized = true

    storedConfig = Config
    Utils = resolveUtils(utilsModule)

    local okConn, connection = pcall(function()
        return RunService.RenderStepped:Connect(function()
            pcall(update)
        end)
    end)

    if okConn and connection then
        table.insert(Chams.Connections, connection)
    end
end

function Chams.cleanup()
    for _, connection in ipairs(Chams.Connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end

    Chams.Connections = {}

    local stale = {}

    for name in pairs(Chams.Pool) do
        stale[#stale + 1] = name
    end

    for _, name in ipairs(stale) do
        releaseHighlight(name)
    end

    Chams.Pool = {}

    Utils = nil
    storedConfig = nil
    Chams.Initialized = false
end

return Chams
