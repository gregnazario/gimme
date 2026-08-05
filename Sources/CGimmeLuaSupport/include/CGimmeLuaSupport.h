#ifndef CGIMME_LUA_SUPPORT_H
#define CGIMME_LUA_SUPPORT_H

#include <stdint.h>
#include "../../GimmeLua/lua54/lua.h"
#include "../../GimmeLua/lua54/lauxlib.h"

typedef struct gimme_ctx_box gimme_ctx_box;

// Function-pointer table registered by Swift at runtime. The C dispatch
// function calls through these instead of linking Swift symbols directly,
// avoiding the SwiftPM mixed-target / link-order problem.
typedef struct gimme_swift_dispatch {
    const char *(*download)(void *sandbox);
    const char *(*extract)(void *sandbox, const char *path);
    int         (*install_dir)(void *sandbox, const char *src);
    int         (*mkdir)(void *sandbox, const char *rel);
    const char *(*dep_path)(void *sandbox, const char *name);
    void        (*host)(void *sandbox, const char **os, const char **arch, const char **ver);
    void        (*set_provides)(void *sandbox, const char *const *bins, int count);
} gimme_swift_dispatch;

// Register the dispatch table. Must be called once before any ctx is used.
void gimme_lua_set_dispatch(const gimme_swift_dispatch *table);

lua_State *gimme_lua_newstate(void);
void gimme_lua_close(lua_State *L);
void gimme_luaL_openlibs_sandboxed(lua_State *L);
int gimme_luaL_dofile(lua_State *L, const char *path);
void gimme_lua_getglobal(lua_State *L, const char *name);
int gimme_lua_isfunction(lua_State *L, int idx);
const char *gimme_lua_tostring(lua_State *L, int idx);
void gimme_lua_register_ctx(lua_State *L, void *sandbox);
void gimme_lua_push_ctx(lua_State *L);
int gimme_lua_pcall(lua_State *L, int nargs, int nresults, int msgh);

#endif
