-- packet logger
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local BufferCodec = require(ReplicatedStorage.Database.Security.Network.BufferCodec)
local Remotes = require(ReplicatedStorage.Database.Security.Remotes)

local PacketLogger = {
    Installed = false
}

local function formatVector(v)
    if typeof(v) == 'Vector3' then
        return string.format('(%.2f, %.2f, %.2f)', v.X, v.Y, v.Z)
    end
    return tostring(v)
end

local function formatTable(tbl, indent)
    indent = indent or 0
    local p = string.rep('  ', indent)
    local lines = {}
    for k, v in pairs(tbl) do
        local keyStr = tostring(k)
        if typeof(v) == 'table' then
            table.insert(lines, p .. keyStr .. ' = {')
            table.insert(lines, formatTable(v, indent + 1))
            table.insert(lines, p .. '}')
        elseif typeof(v) == 'Vector3' then
            table.insert(lines, p .. keyStr .. ' = Vector3' .. formatVector(v))
        elseif typeof(v) == 'Instance' then
            table.insert(lines, p .. keyStr .. ' = ' .. v:GetFullName() .. ' [' .. v.ClassName .. ']')
        else
            table.insert(lines, p .. keyStr .. ' = ' .. tostring(v))
        end
    end
    return table.concat(lines, '\n')
end

local function bufferToHex(buf, maxBytes)
    if typeof(buf) ~= 'buffer' then return tostring(buf) end
    maxBytes = maxBytes or 256
    local len = buffer.len(buf)
    local hex = {}
    local printLen = math.min(len, maxBytes)
    for i = 0, printLen - 1 do
        table.insert(hex, string.format('%02X', buffer.readu8(buf, i)))
        if (i + 1) % 16 == 0 and (i + 1) < printLen then
            table.insert(hex, '\n    ')
        end
    end
    local res = table.concat(hex, ' ')
    if len > maxBytes then
        res = res .. string.format(' ... (%d more bytes)', len - maxBytes)
    end
    return res
end

function PacketLogger.init()
    if PacketLogger.Installed then return end
    PacketLogger.Installed = true

    local ShootWeapon = Remotes.Inventory.ShootWeapon
    if not ShootWeapon then return end

    if not _G.__origShootWeaponSend then
        _G.__origShootWeaponSend = ShootWeapon.Send
    end

    ShootWeapon.Send = function(packet)
        print('\n==================== [SHOOT WEAPON PACKET] ====================')
        print('--- [PRE-COMPRESSION: RAW ARGUMENTS] ---')
        local ok, formatted = pcall(formatTable, packet, 1)
        if ok then
            print(formatted)
        else
            print(tostring(packet))
        end

        local okEnc, buf, refs = pcall(BufferCodec.Encode, packet)
        print('\n--- [POST-COMPRESSION: BINARY BLOB] ---')
        if okEnc and buf then
            local bufLen = (typeof(buf) == 'buffer') and buffer.len(buf) or 0
            print(string.format('Buffer Size: %d bytes', bufLen))
            print('Buffer Hex Dump:\n    ' .. bufferToHex(buf, 256))

            local refCount = (type(refs) == 'table') and #refs or 0
            print(string.format('References Count: %d', refCount))
            if refCount > 0 then
                for idx, refInst in ipairs(refs) do
                    print(string.format('  [%d] %s (%s)', idx, tostring(refInst), typeof(refInst) == 'Instance' and refInst.ClassName or typeof(refInst)))
                end
            end
        else
            print('Failed to encode blob: ' .. tostring(buf))
        end
        print('================================================================\n')

        return _G.__origShootWeaponSend(packet)
    end
end

function PacketLogger.cleanup()
    local ShootWeapon = Remotes.Inventory.ShootWeapon
    if ShootWeapon and _G.__origShootWeaponSend then
        ShootWeapon.Send = _G.__origShootWeaponSend
        _G.__origShootWeaponSend = nil
    end
    PacketLogger.Installed = false
end

return PacketLogger
