--[[
	Project: DisLua.
	Author: imring <fishlake-scripts.ru>.
	License: MIT License.
	
	Project "DisLua" is a parser of bytecode LuaJIT.
    Details: https://github.com/FishLake-Scripts/DisLua
    
    USAGE:
        luajit bytecode-list.lua in.luac [out.lua]
]]
local dislua = require 'dislua.init'
require 'tostring' -- http://lua-users.org/wiki/TableUtils

local function fix_string(str)
    return (str:gsub('.', function(char)
        local byte = char:byte()
        if byte == 7 then return '\\a'
        elseif byte == 8 then return '\\b'
        elseif byte == 12 then return '\\f'
        elseif byte == 10 then return '\\n'
        elseif byte == 13 then return '\\r'
        elseif byte == 9 then return '\\t'
        elseif byte == 11 then return '\\v'
        elseif byte == 34 then return '\\"'
        elseif byte < 32 or byte >= 128 then
            return ('\\x%02X'):format(byte)
        end
        return char
    end))
end

if arg[1] == nil then
    return error('Not found file.')
end

local result, parser = dislua(arg[1])
if result == false then
    return error('File is corrupt or not supported')
end

local result, out = pcall(io.open, arg[2], 'w')
if result == false or type(out) ~= 'userdata' then
    out = io.stdout
end

local jmps_addr = {}

local function is_jump(addr)
    for i = 1, #jmps_addr do
        if jmps_addr[i] == addr then return true end
    end
    return false
end

for i = 1, #parser.protos do
    local proto = parser.protos[i]

    for i = 1, #jmps_addr do
        jmps_addr[i] = nil -- clear
    end

    -- get jumps
    for l = 1, #proto.BCIns do
        local bc = proto.BCIns[l]
        if bc.opcode >= 77 and bc.opcode <= 88 and bc.opcode ~= 81 and bc.opcode ~= 83 and bc.opcode ~= 86
           or bc.opcode == 72 or bc.opcode == 50 then -- http://wiki.luajit.org/Bytecode-2.0#loops-and-branches
            local addr = ( bc.fields[2] - 0x8000 + 1 ) * 4 + bc.pos
            jmps_addr[#jmps_addr + 1] = addr
        end
    end
    
	out:write(('-- BYTECODE -- %s\n'):format(proto))
	out:write(('-- size: %08x args: %d opcodes: %d\n'):format(proto.len, proto.numparams, proto.sizebc))

    for l = 1, #proto.BCIns do
        local bc = proto.BCIns[l]
        local current_pos = bc.pos
        local comments = ''

        local kgcmax = #proto.kgc
        
        if bc.opcode == 51 then -- FNEW
            local field2 = bc.fields[2]
            comments = (' ; -- %s'):format(tostring(proto.kgc[kgcmax - field2]))
        elseif bc.opcode == 54 or bc.opcode == 39 or bc.opcode == 55 or bc.opcode == 6 or bc.opcode == 7 then -- KSTR, GGET, TGETS, etc
            local field2 = bc.fields[2]
            comments = (' ; "%s"'):format(fix_string(proto.kgc[kgcmax - field2]))
        elseif bc.opcode == 42 or bc.opcode == 8 or bc.opcode == 9 then -- KNUM, etc
			local field2 = bc.fields[2]
            comments = (' ; %d'):format(proto.knum[field2 + 1])
        elseif bc.opcode >= 22 and bc.opcode <= 31 then -- http://wiki.luajit.org/Bytecode-2.0#binary-ops
            local field3 = bc.fields[3]
            comments = (' ; %d'):format(proto.knum[field3 + 1])
        elseif bc.opcode == 57 or bc.opcode == 61 then
            local field3 = bc.fields[3]
            comments = (' ; "%s"'):format(fix_string(proto.kgc[kgcmax - field3]))
        elseif bc.opcode >= 77 and bc.opcode <= 88 and bc.opcode ~= 81 and bc.opcode ~= 83 and bc.opcode ~= 86
            or bc.opcode == 72 or bc.opcode == 50 then -- http://wiki.luajit.org/Bytecode-2.0#loops-and-branches
            local field2 = bc.fields[2]
            local addr = ( field2 - 0x8000 + 1 ) * 4 + current_pos
            bc.fields[2] = ('%08x (%d)'):format(addr, field2 - 0x8000 + 1)
        elseif bc.opcode == 53 then -- TDUP
            local field2 = bc.fields[2]
            comments = (' ; %s'):format(table.tostring(proto.kgc[kgcmax - field2]))
        elseif bc.opcode == 45 then -- UGET
            local field2 = bc.fields[2]
			comments = (' ; -- %08X'):format(proto.uv_data[field2])
        elseif bc.opcode == 46 or bc.opcode == 49 then -- USETV
            local field1 = bc.fields[1]
			comments = (' ; -- %08X'):format(proto.uv_data[field1])
        elseif bc.opcode == 47 then -- USETS
            local field1, field2 = bc.fields[1], bc.fields[2]
            comments = (' ; "%s" -- %08X'):format(fix_string(proto.kgc[kgcmax - field2]), proto.uv_data[field1])
        elseif bc.opcode == 48 then -- USETN
            local field1, field2 = bc.fields[1], bc.fields[2]
            comments = (' ; %d -- %08X'):format(proto.knum[field2 + 1], proto.uv_data[field1])
        end
        local start = ' ' .. ( is_jump(current_pos) and '=>' or '  ' ) .. ' ' .. bc.name
		local argstr = table.concat(bc.fields, '\t')
		out:write(('%08x%s (%d)\t%s%s\n'):format(current_pos, start, bc.opcode, argstr, comments))
    end

    out:write('\n')
end

out:close()