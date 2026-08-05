#include "CGimmeLuaSupport.h"
#include "gimme_ctx_box.h"
#include "../../GimmeLua/lua54/lualib.h"
#include <stdlib.h>
#include <string.h>

// Active dispatch table (registered once by Swift).
static gimme_swift_dispatch g_dispatch;
static int g_dispatch_set = 0;

void gimme_lua_set_dispatch(const gimme_swift_dispatch *table) {
    if (table) { g_dispatch = *table; g_dispatch_set = 1; }
}

// Per-state sandbox pointer captured at registration time.
static void *g_active_sandbox = NULL;

// ------------------------------------------------------------------
// Lua API wrappers
// ------------------------------------------------------------------
lua_State *gimme_lua_newstate(void) { return luaL_newstate(); }
void gimme_lua_close(lua_State *L) { lua_close(L); }

void gimme_luaL_openlibs_sandboxed(lua_State *L) {
    // SECURITY: Do NOT call luaL_openlibs() — it opens the `package` library,
    // which exposes `package.loadlib` (dlopen/dlsym) and `package.searchers`,
    // a complete sandbox escape letting a formula run arbitrary native code.
    // Instead, open only the safe standard libraries explicitly.
    static const luaL_Reg safe_libs[] = {
        {LUA_GNAME,       luaopen_base},      // basic fns EXCEPT loadfile/dofile/load (nil'd below)
        {LUA_COLIBNAME,   luaopen_coroutine},
        {LUA_TABLIBNAME,  luaopen_table},
        {LUA_STRLIBNAME,  luaopen_string},
        {LUA_MATHLIBNAME, luaopen_math},
        {LUA_UTF8LIBNAME, luaopen_utf8},
        {LUA_OSLIBNAME,   luaopen_os},        // os, with dangerous fns nil'd below
        {LUA_IOLIBNAME,   luaopen_io},        // io, with dangerous fns nil'd below
        {NULL, NULL}
    };
    // NOTE: deliberately omitted: LUA_LOADLIBNAME (package -> loadlib), LUA_DBLIBNAME (debug).

    for (const luaL_Reg *lib = safe_libs; lib->func; lib++) {
        luaL_requiref(L, lib->name, lib->func, 1);
        lua_pop(L, 1);
    }

    // Remove the `package` global entirely in case any lib pulled it in.
    lua_pushnil(L); lua_setglobal(L, "package");

    // Remove remaining dangerous primitives from base + os + io.
    lua_getglobal(L, "os");
    if (lua_istable(L, -1)) {
        const char *os_danger[] = {"execute","exit","remove","rename","tmpname","setlocale", NULL};
        for (int i = 0; os_danger[i]; i++) {
            lua_pushnil(L); lua_setfield(L, -2, os_danger[i]);
        }
    }
    lua_pop(L, 1);

    lua_getglobal(L, "io");
    if (lua_istable(L, -1)) {
        const char *io_danger[] = {"popen","open","write","read","lines","close","tmpfile", NULL};
        for (int i = 0; io_danger[i]; i++) {
            lua_pushnil(L); lua_setfield(L, -2, io_danger[i]);
        }
    }
    lua_pop(L, 1);

    // Base-library code loaders: a formula must only run via the install(ctx)
    // entrypoint we invoke; it may not load arbitrary source at runtime.
    lua_pushnil(L); lua_setglobal(L, "loadfile");
    lua_pushnil(L); lua_setglobal(L, "dofile");
    lua_pushnil(L); lua_setglobal(L, "load");
    lua_pushnil(L); lua_setglobal(L, "require");
    lua_pushnil(L); lua_setglobal(L, "debug");
}

int gimme_luaL_dofile(lua_State *L, const char *path) { return luaL_dofile(L, path); }
void gimme_lua_getglobal(lua_State *L, const char *name) { lua_getglobal(L, name); }
int gimme_lua_isfunction(lua_State *L, int idx) { return lua_isfunction(L, idx); }
const char *gimme_lua_tostring(lua_State *L, int idx) { return lua_tostring(L, idx); }
int gimme_lua_pcall(lua_State *L, int nargs, int nresults, int msgh) {
    return lua_pcall(L, nargs, nresults, msgh);
}

// ------------------------------------------------------------------
// ctx userdata + dispatch
// ------------------------------------------------------------------
static const char *CTX_META = "gimme.ctx";

// Recover the sandbox pointer from arg 1 (the ctx userdata).
static void *ctx_sandbox(lua_State *L) {
    gimme_ctx_box *box = (gimme_ctx_box *)luaL_checkudata(L, 1, CTX_META);
    return box ? box->sandbox : NULL;
}

static int gimme_ctx_download(lua_State *L) {
    void *sb = ctx_sandbox(L);
    const char *r = (sb && g_dispatch_set && g_dispatch.download) ? g_dispatch.download(sb) : NULL;
    lua_pushstring(L, r ? r : "");
    return 1;
}

static int gimme_ctx_extract(lua_State *L) {
    const char *path = luaL_checkstring(L, 2);
    void *sb = ctx_sandbox(L);
    const char *r = (sb && g_dispatch_set && g_dispatch.extract) ? g_dispatch.extract(sb, path) : NULL;
    if (r) { lua_pushstring(L, r); return 1; }
    // SECURITY: a failed extract (e.g. unsafe archive) must abort, not return nil.
    return luaL_error(L, "ctx:extract failed (unsafe archive or I/O error)");
}

static int gimme_ctx_install_dir(lua_State *L) {
    const char *src = luaL_checkstring(L, 2);
    void *sb = ctx_sandbox(L);
    int ok = (sb && g_dispatch_set && g_dispatch.install_dir) ? g_dispatch.install_dir(sb, src) : -1;
    if (ok == 0) { lua_pushboolean(L, 1); return 1; }
    // SECURITY: a rejected/failed install_dir must abort the install.
    return luaL_error(L, "ctx:install_dir failed (unsafe path or I/O error)");
}

static int gimme_ctx_mkdir(lua_State *L) {
    const char *rel = luaL_checkstring(L, 2);
    void *sb = ctx_sandbox(L);
    int ok = (sb && g_dispatch_set && g_dispatch.mkdir) ? g_dispatch.mkdir(sb, rel) : -1;
    if (ok == 0) { lua_pushboolean(L, 1); return 1; }
    // SECURITY: a mkdir that escapes the prefix must abort the install.
    return luaL_error(L, "ctx:mkdir failed (unsafe path or I/O error)");
}

static int gimme_ctx_set_provides(lua_State *L) {
    luaL_checktype(L, 2, LUA_TTABLE);
    int n = (int)lua_rawlen(L, 2);
    const char **bins = calloc((size_t)(n + 1), sizeof(char *));
    int idx = 0;
    lua_pushnil(L);
    while (lua_next(L, 2) != 0) {
        if (lua_type(L, -1) == LUA_TSTRING) bins[idx++] = lua_tostring(L, -1);
        lua_pop(L, 1);
    }
    void *sb = ctx_sandbox(L);
    if (sb && g_dispatch_set && g_dispatch.set_provides) g_dispatch.set_provides(sb, bins, idx);
    free(bins);
    lua_pushboolean(L, 1); return 1;
}

static int gimme_ctx_dep_path(lua_State *L) {
    const char *name = luaL_checkstring(L, 2);
    void *sb = ctx_sandbox(L);
    const char *r = (sb && g_dispatch_set && g_dispatch.dep_path) ? g_dispatch.dep_path(sb, name) : NULL;
    if (r) { lua_pushstring(L, r); return 1; }
    lua_pushnil(L); return 1;
}

static int gimme_ctx_host(lua_State *L) {
    void *sb = ctx_sandbox(L);
    const char *os = NULL, *arch = NULL, *ver = NULL;
    if (sb && g_dispatch_set && g_dispatch.host) g_dispatch.host(sb, &os, &arch, &ver);
    lua_newtable(L);
    if (os)   { lua_pushstring(L, "os");            lua_pushstring(L, os);   lua_settable(L, -3); }
    if (arch) { lua_pushstring(L, "arch");          lua_pushstring(L, arch); lua_settable(L, -3); }
    if (ver)  { lua_pushstring(L, "macos_version"); lua_pushstring(L, ver);  lua_settable(L, -3); }
    return 1;
}

void gimme_lua_register_ctx(lua_State *L, void *sandbox) {
    g_active_sandbox = sandbox;
    if (luaL_newmetatable(L, CTX_META)) {
        // __index = a table of named C functions; `ctx:method(args)` resolves
        // through it and calls the function with ctx as the first argument.
        lua_newtable(L);  // the __index table
        lua_pushcfunction(L, gimme_ctx_download);    lua_setfield(L, -2, "download");
        lua_pushcfunction(L, gimme_ctx_extract);     lua_setfield(L, -2, "extract");
        lua_pushcfunction(L, gimme_ctx_install_dir); lua_setfield(L, -2, "install_dir");
        lua_pushcfunction(L, gimme_ctx_mkdir);       lua_setfield(L, -2, "mkdir");
        lua_pushcfunction(L, gimme_ctx_set_provides);lua_setfield(L, -2, "set_provides");
        lua_pushcfunction(L, gimme_ctx_dep_path);    lua_setfield(L, -2, "dep_path");
        lua_pushcfunction(L, gimme_ctx_host);        lua_setfield(L, -2, "host");
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);
}

void gimme_lua_push_ctx(lua_State *L) {
    gimme_ctx_box *box = (gimme_ctx_box *)lua_newuserdata(L, sizeof(gimme_ctx_box));
    box->sandbox = g_active_sandbox;
    luaL_setmetatable(L, CTX_META);
}
