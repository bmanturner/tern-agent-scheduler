// Runs one Luau test file under luau-web with a require() shim: every lib/*.luau module (and the
// fake clock as `fake`) is loaded lazily on first require and cached by basename. Test files named
// runner_*.luau also get test/fake_tern.luau prepended, which defines the global `tern`.
// Usage: bun test/run.ts test/<name>.luau
import { LuauState } from "luau-web";
import { readFileSync, readdirSync } from "fs";
import { basename, join } from "path";

const root = join(import.meta.dir, "..");
// `export type` is only legal at chunk top level; inside the loader functions it must be a plain type.
const body = (p: string) => readFileSync(p, "utf8").replace(/^export type /gm, "type ");

const loaders: string[] = [];
for (const f of readdirSync(join(root, "lib")).sort()) {
	if (!f.endsWith(".luau")) continue;
	loaders.push(`__fn[${JSON.stringify(f.slice(0, -5))}] = function()\n${body(join(root, "lib", f))}\nend`);
}
for (const f of readdirSync(join(root, "blocks")).sort()) {
	if (!f.endsWith(".luau")) continue;
	loaders.push(`__fn[${JSON.stringify(f.slice(0, -5))}] = function()\n${body(join(root, "blocks", f))}\nend`);
}
loaders.push(`__fn.fake = function()\n${body(join(root, "test", "fake_chicago.luau"))}\nend`);

const prelude = `
local os = (function() local p = {} for k, v in pairs(os) do p[k] = v end return p end)() -- luau-web os is readonly; tests override time/date on this copy
local __fn = {}
local __mods = setmetatable({}, { __index = function(t, k)
	local f = __fn[k]
	if f == nil then error("require: no module " .. tostring(k)) end
	local v = f()
	rawset(t, k, v)
	return v
end })
local function require(p) return __mods[p:match("([%w_]+)$")] end
${loaders.join("\n")}
`;

const file = process.argv[2];
let test = readFileSync(file, "utf8");
if (basename(file).startsWith("runner_")) {
	test = `${body(join(root, "test", "fake_tern.luau"))}\n${test}`;
}
const s = await LuauState.createAsync();
const f: unknown = s.loadstring(prelude + test);
if (typeof f !== "function") {
	console.log("COMPILE:", f);
	process.exit(1);
}
try {
	await f();
} catch (e) {
	console.log("ERR", e);
}
