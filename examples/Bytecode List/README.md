# Bytecode List
This example displays opcodes of proto.  

### Using
```bash
$ luajit bytecode-list.lua in.luac [out.lua]
```

Example code:
```lua
-- file.lua
function add(a, b)
	return a + b
end

local function sub(a, b)
	return a - b
end

number_1 = 123
local number_2 = 100
print(add(number_1, number_2))
print(sub(number_1, number_2))
```
Compile this file:
```bash
$ luajit -b file.lua file.luac
```
Run `example/bytecode-list.lua`:
```bash
$ luajit example/bytecode-list.lua file.lua
```
And got a list of opcodes:
```lua
-- BYTECODE -- proto:00000006-00000015
-- size: 0000000f args: 2 opcodes: 2
0000000d    ADDVV (32)	2	0	1
00000011    RET1 (76)	2	2

-- BYTECODE -- proto:00000016-00000025
-- size: 0000000f args: 2 opcodes: 2
0000001d    SUBVV (33)	2	0	1
00000021    RET1 (76)	2	2

-- BYTECODE -- proto:00000026-0000008E
-- size: 00000068 args: 0 opcodes: 19
0000002d    FNEW (51)	0	0 ; -- proto:00000006-00000015
00000031    GSET (55)	0	1 ; "add"
00000035    FNEW (51)	0	2 ; -- proto:00000016-00000025
00000039    KSHORT (41)	1	123
0000003d    GSET (55)	1	3 ; "number_1"
00000041    KSHORT (41)	1	100
00000045    GGET (54)	2	4 ; "print"
00000049    GGET (54)	4	1 ; "add"
0000004d    GGET (54)	6	3 ; "number_1"
00000051    MOV (18)	7	1
00000055    CALL (66)	4	0	3
00000059    CALLM (65)	2	1	0
0000005d    GGET (54)	2	4 ; "print"
00000061    MOV (18)	4	0
00000065    GGET (54)	6	3 ; "number_1"
00000069    MOV (18)	7	1
0000006d    CALL (66)	4	0	3
00000071    CALLM (65)	2	1	0
00000075    RET0 (75)	0	1
```