// Umbrella header for the vendored Lua 5.4 C library.
// The Lua headers live one directory up (in lua54/), reached via a
// relative include so external consumers resolve them.
#pragma once

#include "../lua54/lua.h"
#include "../lua54/lauxlib.h"
#include "../lua54/lualib.h"
