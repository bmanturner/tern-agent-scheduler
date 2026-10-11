import { LuauState } from "luau-web";
import { readFileSync } from "fs";
const s = await LuauState.createAsync();
const src = (n:string)=>readFileSync(n,"utf8");
// emulate require by inlining modules
const prelude = `
local __mods = {}
local function require(p) return __mods[p:match("([%w_]+)$")] end
__mods.fake = (function() ${src("fake.luau")} end)()
__mods.cron = (function() ${src("cron.luau")} end)()
__mods.schedule = (function() ${src("schedule.luau")} end)()
__mods.policy = (function() ${src("policy.luau")} end)()
`;
const test = src(process.argv[2]);
const f:any = s.loadstring(prelude + test);
if (typeof f !== "function") { console.log("COMPILE:", f); process.exit(1); }
try { await f(); } catch(e){ console.log("ERR", e); }
