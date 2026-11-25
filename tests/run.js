// Loads an addon the way the game does (files in .toc order, one shared
// namespace table) and runs harness.lua against it, using fengari (Lua VM in JS).
// usage: node run.js <addon folder>
const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const addonDir = process.argv[2];
const addonName = path.basename(addonDir);
const tocPath = path.join(addonDir, addonName + ".toc");

function readNoBom(file) {
  const bytes = fs.readFileSync(file);
  // Must be UTF-8 without BOM, or the client mis-parses the first line.
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    console.error("FAIL: " + file + " starts with a UTF-8 BOM");
    process.exit(1);
  }
  return bytes;
}

const tocLines = readNoBom(tocPath).toString("utf8").split(/\r?\n/);
const files = tocLines.map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
if (!tocLines.some((l) => /^## Interface:.*\b16001\b/.test(l))) {
  console.error("FAIL: .toc does not list interface 16001");
  process.exit(1);
}

// The game's Lua 5.1 refuses to load a file in which one function reaches for
// more than 60 names outside itself (upvalues). This VM is Lua 5.3, which
// allows 255, so the harness would never notice. Count them here. (In Lua 5.3
// a function that touches a global has one upvalue more, _ENV, than in the game.)
const MAX_UPVALUES = 60;
files.forEach((rel) => {
  const full = path.join(addonDir, ...rel.split("\\"));
  if (!fs.existsSync(full)) return; // reported below
  const code = Uint8Array.from(readNoBom(full));
  const C = lauxlib.luaL_newstate();
  if (lauxlib.luaL_loadbuffer(C, code, code.length, to_luastring("@" + rel)) !== lua.LUA_OK) return; // the harness reports it
  (function visit(proto) {
    const hasEnv = proto.upvalues.some((u) => u.name && typeof u.name.getstr === "function" && to_jsstring(u.name.getstr()) === "_ENV");
    const count = proto.upvalues.length - (hasEnv ? 1 : 0);
    if (count > MAX_UPVALUES) {
      console.error("FAIL: " + rel + ": the function at line " + proto.linedefined + " uses " + count +
        " names from outside itself; the game's Lua allows " + MAX_UPVALUES + " (keep them in a table instead)");
      process.exit(1);
    }
    proto.p.forEach(visit);
  })(lua.lua_topointer(C, -1).p);
});

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

// ADDON_FILES = { { name = "Core.lua", source = "..." }, ... } in .toc order
lua.lua_createtable(L, files.length, 0);
files.forEach((rel, i) => {
  const full = path.join(addonDir, ...rel.split("\\"));
  if (!fs.existsSync(full)) {
    console.error("FAIL: .toc lists a file that does not exist: " + rel);
    process.exit(1);
  }
  lua.lua_createtable(L, 0, 2);
  lua.lua_pushstring(L, to_luastring(rel));
  lua.lua_setfield(L, -2, to_luastring("name"));
  lua.lua_pushstring(L, Uint8Array.from(readNoBom(full)));
  lua.lua_setfield(L, -2, to_luastring("source"));
  lua.lua_rawseti(L, -2, i + 1);
});
lua.lua_setglobal(L, to_luastring("ADDON_FILES"));
lua.lua_pushstring(L, to_luastring(addonName));
lua.lua_setglobal(L, to_luastring("ADDON_FOLDER"));

const harness = fs.readFileSync(path.join(__dirname, "harness.lua"));
let status = lauxlib.luaL_loadbuffer(L, Uint8Array.from(harness), harness.length, to_luastring("@harness.lua"));
if (status === lua.LUA_OK) status = lua.lua_pcall(L, 0, 0, 0);
if (status !== lua.LUA_OK) {
  console.error("\nERROR: " + to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(1);
}
