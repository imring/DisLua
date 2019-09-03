local ffi = require 'ffi'
local bit = require 'bit'
local bc_read = require 'dislua.init'
require 'tostring'

local current_path = io.popen'cd':read'*a':gsub('\n', '')
io.write('Enter path to file: ')
local path = io.read()

local name = path:match('.*[\\/](.*)$') or path
local name = name:match('(.*)%..-$') or name

local cl = os.clock()
print('Start.')
local info = bc_read(path)
local res = current_path .. '\\bc\\' .. name .. '-bc.lua'
local file = io.open(res, 'w')
local protos = info:read_protos()

local function fix_string(str)
	local res = str:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\t', '\\t')
	return res
end

local jmps_addr = {}
for i = 1, #protos do
	local proto = protos[i]
	local max = table.maxn(proto.params)
	file:write(('-- BYTECODE -- %s:%08x-%08x\n'):format(path, proto.pos, proto.pos + proto.len))
	file:write(('-- size: %08x args: %d opcodes: %d\n'):format(proto.len, proto.numparams, proto.sizebc))
	for i = 1, #proto.opcodes do
		local info = proto.opcodes[i]
		local current_pos = info.pos
		if info.number >= 77 and info.number <= 88 and info.number ~= 81 and info.number ~= 83 and info.number ~= 86
		   or info.number == 72 or info.number == 50 then
			local addr = ( info.args[2] - 0x8000 + 1 ) * 4 + current_pos
			jmps_addr[addr] = true
			info.args[2] = ('%08x (%d)'):format(addr, info.args[2] - 0x8000 + 1)
		end
	end
	for i = 1, #proto.opcodes do
		local info = proto.opcodes[i]
		local current_pos = info.pos
		local comments = ''
		if info.number == 51 then
			local cproto = proto.params[max - info.args[2]]
			comments = (' ; -- %s:%08x-%08x'):format(path, cproto.pos, cproto.pos + cproto.len)
		elseif info.number == 54 or info.number == 39 or info.number == 55 or info.number == 6 or info.number == 7 or info.number == 47 then
			comments = (' ; "%s"'):format(fix_string(proto.params[max - info.args[2]]))
		elseif info.number == 42 or info.number == 8 or info.number == 9 or info.number == 48 then
			comments = (' ; %d'):format(proto.params[info.args[2] + 1])
		elseif info.number >= 22 and info.number <= 31 then
			comments = (' ; %d'):format(proto.params[info.args[3] + 1])
		elseif info.number == 57 or info.number == 61 then
			comments = (' ; "%s"'):format(fix_string(proto.params[max - info.args[3]]))
		elseif info.number == 53 then
			comments = (' ; %s'):format(table.tostring(proto.params[max - info.args[2]]))
		end
		local start = ' ' .. ( jmps_addr[current_pos] and '=>' or '  ' ) .. ' ' .. info.name
		file:write(('%08x%s (%d)\t%s%s\n'):format(current_pos, start, info.number, table.concat(info.args, '\t'), comments))
	end
	file:write('\n')
end

file:close()

print(('End. Total time: %.03f sec.'):format(os.clock() - cl))