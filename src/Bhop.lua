-- movement physics (bunny hop)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local CharacterClass = require(ReplicatedStorage.Classes.Character)
local Buttons = require(ReplicatedStorage.MovementV2.Buttons)

local Bhop = {
    IsHoldingSpace = false,
    Connections = {},
    Initialized = false
}

local originalSampleInput = nil

function Bhop.init(Config)
    if Bhop.Initialized then return end
    Bhop.Initialized = true

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

    if not _G.__originalSampleInput then
        _G.__originalSampleInput = CharacterClass.SampleInput
    end
    originalSampleInput = _G.__originalSampleInput

    CharacterClass.SampleInput = function(self, p2)
        local sample = originalSampleInput(self, p2)
        if not sample then return sample end

        -- bhop jump logic: jump immediately upon landing
        local bhopEnabled = (Config.BHOP_ENABLED ~= false)
        local isSpaceDown = Bhop.IsHoldingSpace or UserInputService:IsKeyDown(Enum.KeyCode.Space)
        if bhopEnabled and isSpaceDown then
            local mvState = self.MovementState
            local onGround = mvState and mvState.OnGround
            if onGround then
                sample.Buttons = Buttons.with(sample.Buttons, Buttons.Jump, true)
            else
                sample.Buttons = Buttons.with(sample.Buttons, Buttons.Jump, false)
            end
        end

        return sample
    end
end

function Bhop.cleanup()
    if originalSampleInput then
        pcall(function() CharacterClass.SampleInput = originalSampleInput end)
    end
    for _, c in ipairs(Bhop.Connections) do
        pcall(function() c:Disconnect() end)
    end
    Bhop.Connections = {}
    Bhop.IsHoldingSpace = false
    Bhop.Initialized = false
    _G.__originalSampleInput = nil
end

return Bhop
