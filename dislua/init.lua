--[[
	Project: DisLua.
	Author: imring <fishlake-scripts.ru>.
    License: MIT License.
    
	Project "DisLua" is a parser of bytecode LuaJIT.
	Details: https://github.com/FishLake-Scripts/DisLua
]]

local readers = {
    'luajit-2'
}

return function(path)
    local bool, parser
    for i, k in ipairs(readers) do
        bool, parser = pcall(require('dislua.' .. k .. '.read'), path)
        if bool == true then break end
    end
    if bool == false then return false end
    return bool, parser
end