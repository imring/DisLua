local ffi = require 'ffi'
local bit = require 'bit'
local opcodes = require 'dislua.opcodes'

local function bc_read(path)
	local file = assert(io.open(path, 'rb'), 'File doesn\'t exist')
	local text = file:read'*a'
	local buffer = ffi.new('char[?]', #text + 1, text)

	local bc = {
		path = path,
		index = 0,
		maxindex = ffi.sizeof(buffer) - 1,
		buffer = buffer,

		flags = 0,
		chunkname = '',
		protos = {}
	}

	function bc:get_byte()
		assert(self.index + 1 <= self.maxindex)
		local val = self.buffer[self.index]
		self.index = self.index + 1
		return val
	end

	function bc:get_short()
		assert(self.index + 2 <= self.maxindex)
		local val = ffi.cast('uint16_t*', self.buffer + self.index)[0]
		self.index = self.index + 2
		return val
	end

	function bc:get_long()
		assert(self.index + 4 <= self.maxindex)
		local val = ffi.cast('uint32_t*', self.buffer + self.index)[0]
		self.index = self.index + 4
		return val
	end

	function bc:get_uleb128()
		local result, shift = 0, 0
		while true do
			local b = self:get_byte()
			result = bit.bor(result, bit.lshift(bit.band(b, 0x7f), shift))
			shift = shift + 7
			if bit.band(b, 0x80) == 0 then break end
		end
		return result
	end

	function bc:get_string(len)
		assert(self.index + len <= self.maxindex)
		local val = ffi.string(self.buffer + self.index, len)
		self.index = self.index + len
		return val
	end

	function bc:get_number(type)
		local c = type == 4 and 'double*' or type == 2 and 'int64_t*' or 'uint64_t*'
		local lo = self:get_uleb128()
		local hi = self:get_uleb128()
		local num = ffi.cast(c, ffi.new('int[2]', lo, hi))
		return num[0]
	end

	function bc:get_tabk()
		local type = self:get_uleb128()
		if type >= 5 then return self:get_string(type - 5)
		elseif type == 4 then return self:get_number()
		elseif type == 3 then return self:get_uleb128()
		elseif type == 2 then return true
		elseif type == 1 then return false
		else assert(type == 0) end
	end

	function bc:read_header()
		if self:get_byte() ~= 0x4c or
		   self:get_byte() ~= 0x4a or
		   self:get_byte() ~= 2 then return false end

		self.flags = self:get_uleb128()
		if bit.band(self.flags, bit.bnot(0xf)) ~= 0 then return false end
		if bit.band(self.flags, 0x8) ~= 0 then return false end
		if bit.band(self.flags, 0x2) ~= 0 then
			self.chunkname = self.path
		else
			local len = self:get_uleb128()
			self.chunkname = self:get_string(len)
		end
		return true
	end

	function bc:read_bytecodeinfo(info)
		local opcode = bit.band(info, 0xff)
		local op = opcodes[opcode]
		if op == nil then
			print(('unknown opcode %d, index: %08x'):format(opcode, self.index - 4))
			op = { 'UNK', 1 }
		end
		local args = {}
		args[1] = bit.band(bit.rshift(info, 8), 0xff)
		if op[2] == 1 then -- AD
			args[2] = bit.rshift(info, 16)
		elseif op[2] == 2 then -- ABC
			args[2] = bit.rshift(info, 24)
			args[3] = bit.band(bit.rshift(info, 16), 0xff)
		else error('Error read info of bytecode.') end
		return opcode, op[1], args
	end

	function bc:read_knum()
		local isnum = bit.band(self.buffer[self.index], 1)
		local lo = self:get_uleb128() -- self:get_uleb128_33()
		if isnum == 1 then
			local hi = self:get_uleb128()
			local res = ffi.cast('double*', ffi.new('int[2]', lo, hi))
			return res[0]
		end
		if bit.band(lo, bit.lshift(1, 31)) ~= 0 then
			lo = lo - bit.lshift(1, 32)
		end
		return lo
	end

	function bc:read_proto()
		local proto = {
			pos = self.index,
			sizedbg = 0,

			opcodes = {},
			uv_data = {},
			params = {}
		}
		proto.flags = self:get_byte()
		proto.numparams = self:get_byte()
		proto.framesize = self:get_byte()
		proto.sizeuv = self:get_byte()
		proto.sizekgc = self:get_uleb128()
		proto.sizekn = self:get_uleb128()
		proto.sizebc = self:get_uleb128()
		if bit.band(self.flags, 0x2) == 0 then
			proto.sizedbg = self:get_uleb128()
			if proto.sizedbg ~= 0 then
				proto.firstline = self:get_uleb128()
				proto.numline = self:get_uleb128()
			end
		end
		for i = 1, proto.sizebc do
			local pos = self.index
			local bc = self:get_long()
			local opcodenumb, opcodename, args = self:read_bytecodeinfo(bc)
			proto.opcodes[i] = { pos = pos, number = opcodenumb, name = opcodename, args = args }
		end
		for i = 1, proto.sizeuv do
			local uv = self:get_short()
			local is_local = bit.band(uv, 0x8000)
			local immutable = bit.band(uv / 0x4000, 1)
			local dhash = bit.lshift(uv, 24)
			proto.uv_data[i] = uv
			-- print(is_local, immutable, bit.band(uv, 0xff))
		end
		local childc = #self.protos
		for i = 1, proto.sizekgc do
			local type = self:get_uleb128()
			if type >= 5 then
				local len = type - 5
				proto.params[proto.sizekn + i] = self:get_string(len)
			elseif type == 1 then
				local narray = self:get_uleb128()
				local nhash = self:get_uleb128()
				local t = {}
				for i = 1, narray do
					t[i - 1] = self:get_tabk()
				end
				for i = 1, nhash do
					local k = self:get_tabk()
					local v = self:get_tabk()
					t[k] = v
				end
				proto.params[proto.sizekn + i] = t
			elseif type ~= 0 then
				local number = self:get_number(type)
				if type == 4 then
					local imaginary = self:get_number(type)
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
			proto.params[i] = self:read_knum()
			-- print(proto.params[i])
		end
		proto.len = self.index - proto.pos
		local sthis = tostring(proto):gsub('table', 'proto')
		setmetatable(proto, { __tostring = function(this)
			return sthis
		end })
		return proto
	end

	function bc:read_protos()
		if #self.protos == 0 then
			while true do
				if self.index < self.maxindex and self.buffer[self.index] == 0 then
					self.index = self.index + 1
					break
				end
				local len = self:get_uleb128()
				if len == 0 then break end
				local startp = self.index
				local pt = self:read_proto()
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

	assert(bc:get_byte() == 0x1b)
	if bc:read_header() == false then
		error('Error read header.')
	end
	bc:read_protos()

	return bc
end

return bc_read