--[[
	Project: DisLua.
	Author: imring <fishlake-scripts.ru>.
	License: MIT License.
	
	Project "DisLua" is a parser of bytecode LuaJIT.
	Details: https://github.com/FishLake-Scripts/DisLua
]]
local ffi = require 'ffi'
local bit = require 'bit'

local opcodes = require 'dislua.luajit-2.opcodes'

local LJ_FR2 = 0

local BCDUMP_HEAD1 = 0x1b
local BCDUMP_HEAD2 = 0x4c
local BCDUMP_HEAD3 = 0x4a

local BCDUMP_VERSION = 2

local BCDUMP_F_BE = 0x1
local BCDUMP_F_STRIP = 0x2
local BCDUMP_F_FFI = 0x4
local BCDUMP_F_FR2 = 0x8

local BCDUMP_F_KNOWN = (BCDUMP_F_FR2*2-1)

local PROTO_VARARG = 0x2

local BCDUMP_KGC_CHILD = 0
local BCDUMP_KGC_TAB = 1
local BCDUMP_KGC_I64 = 2
local BCDUMP_KGC_U64 = 3
local BCDUMP_KGC_COMPLEX = 4
local BCDUMP_KGC_STR = 5

local BCDUMP_KTAB_NIL = 0
local BCDUMP_KTAB_FALSE = 1
local BCDUMP_KTAB_TRUE = 2
local BCDUMP_KTAB_INT = 3
local BCDUMP_KTAB_NUM = 4
local BCDUMP_KTAB_STR = 5

local function bc_op(i) return bit.band(i, 0xff) end
local function bc_a(i) return bit.band(bit.rshift(i, 8), 0xff) end
local function bc_b(i) return bit.rshift(i, 24) end
local function bc_c(i) return bit.band(bit.rshift(i, 16), 0xff) end
local function bc_d(i) return bit.rshift(i, 16) end

return function(path)
	local file = io.open(path, 'rb')
	local text = file:read '*a'
	file:close()

	local len = #text
	local buffer = {
		pointer = ffi.new('char[?]', len + 1, text),
		index = 0,
		maxindex = len
	}

	local parser = {
		compiled = 'LuaJIT v2',
		path = path,
		buffer = buffer,
		flags = 0,
		protos = {},
		_protos = {} -- for kgc
	}

	function parser:read_byte()
		local buffer = self.buffer
		assert(buffer.index < buffer.maxindex)
		local result = buffer.pointer[buffer.index]
		buffer.index = buffer.index + 1
		return result
	end

	function parser:read_ubyte()
		local result = self:read_byte()
		if result < 0 then result = 256 + result end
		return result
	end

	function parser:read_short()
		local buffer = self.buffer
		local result = ffi.cast('uint16_t*', buffer.pointer + buffer.index)[0]
		buffer.index = buffer.index + 2
		return result
	end

	function parser:read_long()
		local buffer = self.buffer
		local result = ffi.cast('uint32_t*', buffer.pointer + buffer.index)[0]
		buffer.index = buffer.index + 4
		return result
	end

	function parser:read_mem(len)
		local buffer = self.buffer
		local str = ffi.string(buffer.pointer + buffer.index, len)
		buffer.index = buffer.index + len
		-- print(#self.protos, buffer.index, buffer.maxindex, len)
		assert(buffer.index <= buffer.maxindex)
		return str
	end

	function parser:read_uleb128()
		local buffer = self.buffer

		local v = self:read_ubyte()
		if v >= 0x80 then
			local sh = 0
			v = bit.band(v, 0x7f)

			while true do
				local b = buffer.pointer[buffer.index]
				if b < 0 then b = 256 + b end

				sh = sh + 7
				v = bit.bor(v, bit.lshift( bit.band(b, 0x7f), sh ))
				if self:read_ubyte() < 0x80 then break end
			end
		end

		assert(buffer.index <= buffer.maxindex)
		return v
	end

	function parser:read_uleb128_33()
		local buffer = self.buffer

		local v = bit.rshift(self:read_ubyte(), 1)
		if v >= 0x40 then
			local sh = -1
			v = bit.band(v, 0x3f)

			while true do
				local b = buffer.pointer[buffer.index]
				if b < 0 then b = 256 + b end
				
				sh = sh + 7
				v = bit.bor(v, bit.lshift( bit.band(b, 0x7f), sh ))
				if self:read_ubyte() < 0x80 then break end
			end
		end

		assert(buffer.index <= buffer.maxindex)
		return v
	end

	function parser:read_ktabk()
		local tp = self:read_uleb128()
		if tp >= BCDUMP_KTAB_STR then
			return self:read_mem(tp - BCDUMP_KTAB_STR)
		elseif tp == BCDUMP_KTAB_INT then
			return tonumber(ffi.cast('int32_t', self:read_uleb128()))
		elseif tp == BCDUMP_KTAB_NUM then
			local data = ffi.new('uint32_t[2]', self:read_uleb128(), self:read_uleb128())
			result = ffi.cast('double*', data)[0]
			return result
		else
			assert(tp <= BCDUMP_KTAB_TRUE)
			return ({ nil, false, true })[tp + 1]
		end
	end

	function parser:read_ktab()
		local narray = self:read_uleb128()
		local nhash = self:read_uleb128()
		local t = {}
		for i = 1, narray do
			t[i - 1] = self:read_ktabk()
		end
		for i = 1, nhash do
			t[self:read_ktabk()] = self:read_ktabk()
		end
		return t
	end

	function parser:read_bytecode(pt, size)
		local bc = pt.BCIns
		for i = 1, size do
			local cpos = self.buffer.index
			local instruction = self:read_long()
			local op = { pos = cpos, name = 'UNK', opcode = bc_op(instruction), sizefield = 2, fields = {} }
			local info = opcodes[op.opcode]
			if info ~= nil then
				op.name = info[1]
				op.sizefield = info[2] + 1
			end
			op.fields[1] = bc_a(instruction)
			if op.sizefield == 2 then -- AD
				op.fields[2] = bc_d(instruction)
			elseif op.sizefield == 3 then -- ABC
				op.fields[2] = bc_b(instruction)
				op.fields[3] = bc_c(instruction)
			end
			bc[i] = op
		end
	end

	function parser:read_uv(pt, size)
		local uv = pt.uv_data
		for i = 0, size - 1 do
			uv[i] = self:read_short()
		end
	end

	function parser:read_kgc(pt, size)
		local kgc = pt.kgc
		for i = 0, size - 1 do
			local tp = self:read_uleb128()
			if tp >= BCDUMP_KGC_STR then
				local len = tp - BCDUMP_KGC_STR
				local str = self:read_mem(len)
				kgc[i] = str
			elseif tp == BCDUMP_KGC_TAB then
				kgc[i] = self:read_ktab()
			elseif tp ~= BCDUMP_KGC_CHILD then
				local id = tp == BCDUMP_KGC_COMPLEX and 'complex double' or tp == BCDUMP_KGC_I64 and 'int64_t' or 'uint64_t'
				local data = ffi.new('uint32_t[?]', ffi.sizeof(id) / 4)
				data[0] = self:read_uleb128()
				data[1] = self:read_uleb128()
				if tp == BCDUMP_KGC_COMPLEX then
					data[2] = self:read_uleb128()
					data[3] = self:read_uleb128()
				end
				local result = ffi.cast(id .. '*', data)[0]
				kgc[i] = result
			else
				assert(tp == BCDUMP_KGC_CHILD)
				if #self._protos == 0 then error('LJ_ERR_BCFMT') end
				local childc = self._protos[#self._protos]
				self._protos[#self._protos] = nil
				kgc[i] = childc
			end
		end
	end

	function parser:read_knum(pt, size)
		local knum = pt.knum
		for i = 1, size do
			local isnum = bit.band(self.buffer.pointer[self.buffer.index], 1)
			local result = self:read_uleb128_33()
			if isnum > 0 then
				local data = ffi.new('uint32_t[2]', result, self:read_uleb128())
				result = ffi.cast('double*', data)[0]
			end
			knum[i] = result
		end
	end

	function parser:read_header()
		local flags = 0
		if self:read_byte() ~= BCDUMP_HEAD2 or
		   self:read_byte() ~= BCDUMP_HEAD3 or
		   self:read_byte() ~= BCDUMP_VERSION then return false end

		flags = self:read_uleb128()
		self.flags = flags
		if bit.band(flags, bit.bnot(BCDUMP_F_KNOWN)) ~= 0 then return false end
		if bit.band(flags, BCDUMP_F_FR2) ~= LJ_FR2*BCDUMP_F_FR2 then return false end
		-- if bit.band(flags, BCDUMP_F_FFI) > 0 then return false end
		if bit.band(flags, BCDUMP_F_STRIP) > 0 then
			self.chunkname = table.concat(arg)
		else
			local len = self:read_uleb128()
			self.chunkname = self:read_mem(len)
		end
		return true
	end

	function parser:read_proto()
		local framesize, numparams, flags, sizeuv, sizekgc, sizekn, sizebc, sizept
	
		local start = self.buffer.index
		flags = self:read_byte()
		numparams = self:read_byte()
		framesize = self:read_byte()
		sizeuv = self:read_byte()
		sizekgc = self:read_uleb128()
		sizekn = self:read_uleb128()
		sizebc = self:read_uleb128()
	
		if bit.band(self.flags, BCDUMP_F_STRIP) <= 0 then
			error('Not supported')
		end
	
		local pt = {
			pos = start,

			flags = flags,
			numparams = numparams,
			framesize = framesize,
			sizeuv = sizeuv,
			sizekgc = sizekgc,
			sizekn = sizekn,
			sizebc = sizebc,
	
			BCIns = {},
			uv_data = {},
			kgc = {},
			knum = {}
		}
	
		self:read_bytecode(pt, sizebc)
		self:read_uv(pt, sizeuv)
		self:read_kgc(pt, sizekgc)
		self:read_knum(pt, sizekn)

		local ptend = self.buffer.index
		pt.len = ptend - pt.pos
		setmetatable(pt, { __tostring = function(this)
			return ('proto:%08X-%08X'):format(pt.pos, ptend)
		end })
		return pt
	end

	assert(parser:read_byte() == BCDUMP_HEAD1)
	if not parser:read_header() then
		error('LJ_ERR_BCFMT')
	end
	while true do
		if buffer.index < buffer.maxindex and buffer.pointer[buffer.index] == 0 then
			buffer.index = buffer.index + 1
			break
		end
		local len = parser:read_uleb128()
		if len <= 0 then break end
		local startp = buffer.index
		local pt = parser:read_proto()
		-- print(buffer.index, startp + len, len)
		if buffer.index ~= startp + len then
			error('LJ_ERR_BCBAD')
		end
		parser.protos[#parser.protos + 1] = pt
		parser._protos[#parser._protos + 1] = pt
	end
	if buffer.maxindex - buffer.index > 0 then
		error('LJ_ERR_BCBAD')
	end
	parser._protos = nil
	
	return parser
end