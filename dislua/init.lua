local assert, error, require = assert, error, require
local open = io.open
local gsub = string.gsub

local ffi = require 'ffi'
local bit = require 'bit'
local opcodes = require 'dislua.opcodes'

local new, cast, sizeof, fstring = ffi.new, ffi.cast, ffi.sizeof, ffi.string
local bor, lshift, band, rshift = bit.bor, bit.lshift, bit.band, bit.rshift

local function bcget_byte(self)
	assert(self.index + 1 <= self.maxindex)
	local val = self.buffer[self.index]
	self.index = self.index + 1
	return val
end

local function bcget_short(self)
	assert(self.index + 2 <= self.maxindex)
	local val = cast('uint16_t*', self.buffer + self.index)[0]
	self.index = self.index + 2
	return val
end

local function bcget_long(self)
	assert(self.index + 4 <= self.maxindex)
	local val = cast('uint32_t*', self.buffer + self.index)[0]
	self.index = self.index + 4
	return val
end

local function bcget_uleb128(self)
	local result, shift = 0, 0
	while true do
		local b = bcget_byte(self)
		result = bor(result, lshift(band(b, 0x7f), shift))
		shift = shift + 7
		if band(b, 0x80) == 0 then break end
	end
	return result
end

local function bcget_string(self, len)
	assert(self.index + len <= self.maxindex)
	local val = fstring(self.buffer + self.index, len)
	self.index = self.index + len
	return val
end

local function bcget_number(self, type)
	local lo = bcget_uleb128(self)
	local hi = bcget_uleb128(self)
	local num = cast('double*', new('int[2]', lo, hi))
	return num[0]
end

local function bcget_tabk(self)
	local type = bcget_uleb128(self)
	if type >= 5 then return bcget_string(self, type - 5)
	elseif type == 4 then return bcget_number(self)
	elseif type == 3 then return bcget_uleb128(self)
	elseif type == 2 then return true
	elseif type == 1 then return false
	else assert(type == 0) end
end

local function bcread_header(self)
	if bcget_byte(self) ~= 0x4c or
	   bcget_byte(self) ~= 0x4a or
	   bcget_byte(self) ~= 2 then return false end

	self.flags = bcget_uleb128(self)
	if band(self.flags, -0x10 --[[bnot(0xf)]]) ~= 0 then return false end
	if band(self.flags, 0x8) ~= 0 then return false end
	if band(self.flags, 0x2) ~= 0 then
		self.chunkname = self.path
	else
		local len = bcget_uleb128(self)
		self.chunkname = bcget_string(self, len)
	end
	return true
end

local function bcread_bytecodeinfo(self, info)
	local opcode = band(info, 0xff)
	local op = opcodes[opcode]
	if op == nil then
		print(('unknown opcode %d, index: %08x'):format(opcode, self.index - 4))
		op = { 'UNK', 1 }
	end
	local args = {}
	args[1] = band(rshift(info, 8), 0xff)
	if op[2] == 1 then -- AD
		args[2] = rshift(info, 16)
	elseif op[2] == 2 then -- ABC
		args[2] = rshift(info, 24)
		args[3] = band(rshift(info, 16), 0xff)
	else error('Error read info of bytecode.') end
	return opcode, op[1], args
end

local function bcread_knum(self)
	local isnum = band(self.buffer[self.index], 1)
	local lo = bcget_uleb128(self) -- bcget_uleb128_33(self)
	if isnum == 1 then
		local hi = bcget_uleb128(self)
		local res = cast('double*', new('int[2]', lo, hi))
		return res[0]
	end
	if band(lo, lshift(1, 31)) ~= 0 then
		lo = lo - lshift(1, 32)
	end
	return lo
end

local function bcread_proto(self)
	local proto = {
		pos = self.index,
		sizedbg = 0,

		opcodes = {},
		uv_data = {},
		params = {},
		jumps = {}
	}
	proto.flags = bcget_byte(self)
	proto.numparams = bcget_byte(self)
	proto.framesize = bcget_byte(self)
	proto.sizeuv = bcget_byte(self)
	proto.sizekgc = bcget_uleb128(self)
	proto.sizekn = bcget_uleb128(self)
	proto.sizebc = bcget_uleb128(self)
	if band(self.flags, 0x2) == 0 then
		--[[proto.sizedbg = bcget_uleb128(self)
		if proto.sizedbg ~= 0 then
			proto.firstline = bcget_uleb128(self)
			proto.numline = bcget_uleb128(self)
		end]]
		error('Currently does not support debug info.')
	end
	for i = 1, proto.sizebc do
		local pos = self.index
		local bc = bcget_long(self)
		local opcodenumb, opcodename, args = bcread_bytecodeinfo(self, bc)
		if opcodenumb >= 77 and opcodenumb <= 88 and opcodenumb ~= 81 and opcodenumb ~= 83 and opcodenumb ~= 86
		   or opcodenumb == 72 or opcodenumb == 50 then -- http://wiki.luajit.org/Bytecode-2.0#loops-and-branches
			local addr = ( args[2] - 0x8000 + 1 ) * 4 + pos
			proto.jumps[addr] = true
		end
		proto.opcodes[i] = { pos = pos, number = opcodenumb, name = opcodename, args = args }
	end
	for i = 1, proto.sizeuv do
		local uv = bcget_short(self)
		local is_local = band(uv, 0x8000)
		local immutable = band(uv / 0x4000, 1)
		local dhash = lshift(uv, 24)
		proto.uv_data[i] = uv
		-- print(is_local, immutable, band(uv, 0xff))
	end
	local childc = #self.protos
	for i = 1, proto.sizekgc do
		local type = bcget_uleb128(self)
		if type >= 5 then
			local len = type - 5
			proto.params[proto.sizekn + i] = bcget_string(self, len)
		elseif type == 1 then
			local narray = bcget_uleb128(self)
			local nhash = bcget_uleb128(self)
			local t = {}
			for i = 1, narray do
				t[i - 1] = bcget_tabk(self)
			end
			for i = 1, nhash do
				local k = bcget_tabk(self)
				local v = bcget_tabk(self)
				t[k] = v
			end
			proto.params[proto.sizekn + i] = t
		elseif type ~= 0 then
			local number = bcget_number(self, type)
			if type == 4 then
				local imaginary = bcget_number(self, type)
				proto.params[proto.sizekn + i] = { number, imaginary }
			else
				proto.params[proto.sizekn + i] = number
			end
		else
			proto.params[proto.sizekn + i] = self.protos[childc]
			childc = childc - 1
		end
	end
	for i = 1, proto.sizekn do
		proto.params[i] = bcread_knum(self)
		-- print(proto.params[i])
	end
	proto.len = self.index - proto.pos
	local sthis = gsub(tostring(proto), 'table', 'proto')
	setmetatable(proto, { __tostring = function(this)
		return sthis
	end })
	return proto
end

local function bcread_protos(self)
	if #self.protos == 0 then
		while true do
			if self.index < self.maxindex and self.buffer[self.index] == 0 then
				self.index = self.index + 1
				break
			end
			local len = bcget_uleb128(self)
			if len == 0 then break end
			local startp = self.index
			local pt = bcread_proto(self)
			-- print(self.index, startp + len, len)
			if self.index ~= startp + len then
				error('Error read proto.')
			end
			self.protos[#self.protos + 1] = pt
		end
		if self.maxindex - self.index > 0 then error('Error read protos.') end
	end
	return self.protos
end

local function bc_read(path)
	local file = assert(open(path, 'rb'), 'File doesn\'t exist')
	local text = file:read('*a')
	local buffer = new('char[?]', #text + 1, text)

	local bc = {
		path = path,
		index = 0,
		maxindex = sizeof(buffer) - 1,
		buffer = buffer,

		flags = 0,
		chunkname = '',
		protos = {},

		get_byte = bcget_byte,
		get_short = bcget_short,
		get_long = bcget_long,
		get_uleb128 = bcget_uleb128,
		get_string = bcget_string,
		get_number = bcget_number,
		get_tabk = bcget_tabk,
		read_header = bcread_header,
		read_bytecodeinfo = bcread_bytecodeinfo,
		read_knum = bcread_knum,
		read_proto = bcread_proto,
		read_protos = bcread_protos
	}

	assert(bcget_byte(bc) == 0x1b)
	if bcread_header(bc) == false then
		error('Error read header.')
	end
	bcread_protos(bc)

	return bc
end

return bc_read