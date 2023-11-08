-- src/setup.lua
local version = _VERSION:match("%d+%.%d+")

package.path = 'lua_modules/share/lua/' .. version ..
    '/?.lua;lua_modules/share/lua/' .. version .. '/?/init.lua;' ..
    '\\dev\\denon_dn_900_r_v_1_0_0\\src\\?.lua;' .. package.path

package.cpath = 'lua_modules/lib/lua/' .. version .. '/?.so;' ..
    'lua_modules/lib/lua/' .. version .. '/?.dll;' .. package.cpath