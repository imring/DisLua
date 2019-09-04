local require = require
local popen, write, read, open = io.popen, io.write, io.read, io.open
local gsub, match, format = string.gsub, string.match, string.format
local clock = os.clock

local bc_read = require 'dislua.init'
require 'tostring' -- http://lua-users.org/wiki/TableUtils

local tabletostring = table.tostring

local current_path = gsub(popen('cd'):read('*a'), '\n', '')
write('Enter path to file: ')
local path = read()

local name = match(path, '.*[\\/](.*)$') or path
name = match(name, '(.*)%..-$') or name
local res = current_path .. '\\bc\\' .. name .. '-bc.lua'
local file = open(res, 'w')

local cl = clock()
print('Start.')
local info = bc_read(path)
local protos = info:read_protos()

local function fix_string(str)
	str = gsub(str, '\\', '\\\\')
	str = gsub(str, '"', '\\"')
	str = gsub(str, '\n', '\\n')
	str = gsub(str, '\t', '\\t')
	return str
end

local jmps_addr = {}
for i = 1, #protos do
	local proto = protos[i]
	local max = #proto.params
	file:write(format('-- BYTECODE -- %s:%08x-%08x\n', path, proto.pos, proto.pos + proto.len))
	file:write(format('-- size: %08x args: %d opcodes: %d\n', proto.len, proto.numparams, proto.sizebc))
	for i = 1, #proto.opcodes do
		local info = proto.opcodes[i]
		local current_pos = info.pos
		local comments = ''
		if info.number == 51 then -- FNEW
			local index = max - info.args[2]
			local cproto = proto.params[index]
			comments = format(' ; -- %s:%08x-%08x', path, cproto.pos, cproto.pos + cproto.len)
		elseif info.number == 54 or info.number == 39 or info.number == 55 or info.number == 6 or info.number == 7 or info.number == 47 then -- KSTR, GGET, TGETS, etc
			local index = max - info.args[2]
			local str = fix_string(proto.params[index])
			comments = format(' ; "%s"', str)
		elseif info.number == 42 or info.number == 8 or info.number == 9 or info.number == 48 then -- KNUM, USETN, etc
			local index = info.args[2] + 1
			comments = format(' ; %d', proto.params[index])
		elseif info.number >= 22 and info.number <= 31 then -- http://wiki.luajit.org/Bytecode-2.0#binary-ops
			local index = info.args[3] + 1
			comments = format(' ; %d', proto.params[index])
		elseif info.number == 57 or info.number == 61 then
			local index = max - info.args[3]
			local str = fix_string(proto.params[index])
			comments = format(' ; "%s"', str)
		elseif info.number == 53 then
			local index = max - info.args[2]
			local tabstr = tabletostring(proto.params[index])
			comments = format(' ; %s', tabstr)
		elseif info.number >= 77 and info.number <= 88 and info.number ~= 81 and info.number ~= 83 and info.number ~= 86
			or info.number == 72 or info.number == 50 then -- http://wiki.luajit.org/Bytecode-2.0#loops-and-branches
			local addr = ( info.args[2] - 0x8000 + 1 ) * 4 + current_pos
			info.args[2] = format('%08x (%d)', addr, info.args[2] - 0x8000 + 1)
		end
		local start = ' ' .. ( proto.jumps[current_pos] and '=>' or '  ' ) .. ' ' .. info.name
		local argstr = ''
		for i = 1, #info.args do
			argstr = argstr .. info.args[i]
			if i ~= #info.args then argstr = argstr .. '\t' end
		end
		file:write(format('%08x%s (%d)\t%s%s\n', current_pos, start, info.number, argstr, comments))
	end
	file:write('\n')
end

print(format('End. Total time: %.03f sec.', clock() - cl))

file:close()