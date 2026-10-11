// Runs every test/t*.luau and test/runner_*.luau through test/run.ts and compares stdout with
// test/golden/<name>.txt. Exit 1 on any diff, ERR or COMPILE line. `--update` rewrites the goldens.
import { readdirSync, readFileSync, writeFileSync, existsSync } from "fs";
import { join } from "path";

const dir = import.meta.dir;
const update = process.argv.includes("--update");
const files = readdirSync(dir)
	.filter((f) => /^(t\d+|runner_\w+)\.luau$/.test(f))
	.sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));

let failed = 0;
for (const f of files) {
	const name = f.slice(0, -5);
	const proc = Bun.spawnSync(["bun", join(dir, "run.ts"), join(dir, f)], { cwd: join(dir, "..") });
	const out = proc.stdout.toString() + proc.stderr.toString();
	const bad = out.split("\n").filter((l) => l.startsWith("ERR") || l.startsWith("COMPILE"));
	const golden = join(dir, "golden", `${name}.txt`);
	if (bad.length > 0 || proc.exitCode !== 0) {
		failed++;
		console.log(`FAIL ${name}\n${out}`);
		continue;
	}
	if (update) {
		writeFileSync(golden, out);
		console.log(`updated ${name}`);
		continue;
	}
	if (!existsSync(golden)) {
		failed++;
		console.log(`FAIL ${name}: no golden ${golden}\n${out}`);
		continue;
	}
	const want = readFileSync(golden, "utf8");
	if (want !== out) {
		failed++;
		const a = want.split("\n");
		const b = out.split("\n");
		const lines: string[] = [];
		for (let i = 0; i < Math.max(a.length, b.length); i++) {
			if (a[i] !== b[i]) lines.push(`  line ${i + 1}\n    want: ${a[i] ?? "<eof>"}\n    got:  ${b[i] ?? "<eof>"}`);
		}
		console.log(`FAIL ${name}\n${lines.slice(0, 20).join("\n")}`);
		continue;
	}
	console.log(`ok ${name}`);
}
process.exit(failed > 0 ? 1 : 0);
