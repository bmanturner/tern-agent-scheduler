-- Images in a prompt: staged into the run dir, links rewritten in the snapshot, extra @-attachments in the
-- argv, the preamble and the run record say what was and wasn't attached. A prompt without images is untouched.
local jobs, runner = __mods.jobs, __mods.runner

fake.dirs["/home/u/proj"] = true
fake.dirs["/home/u/proj2"] = true
fake.set_wall(fake.chicago(2026, 10, 12, 8, 59, 30))

-- scripted staging: argv = { sh, -c, script, "sh", src, dst, max }
local stage_calls = {}
fake.override.sh = function(argv)
	if argv[2] ~= "-c" or argv[4] ~= "sh" then
		return nil
	end
	local src, dst = argv[5], argv[6]
	stage_calls[#stage_calls + 1] = { src = src, dst = dst, max = argv[7], script = argv[3] }
	local status = 0
	if src:find("gone.png", 1, true) then
		status = 3
	end
	return { status = status, stdout = "", stderr = "", timed_out = false }
end

runner.load()
fake.advance(1000)
local prompt = table.concat({
	"Look at ![a](shot.png) and ![b](~/pics/b.JPG)",
	"Again ![a2](<shot.png>)",
	"Missing ![c](gone.png) remote ![d](https://example.com/r.png)",
	"",
}, "\n")
local a = jobs.create({ name = "with-images", prompt = "x", when = "0 9 * * *", cwd = "/home/u/proj" }, prompt, "user", os.time())
local b = jobs.create({ name = "no-images", prompt = "x", when = "0 9 * * *", cwd = "/home/u/proj2" }, "Plain text, [a link](x.png) but no image", "user", os.time())
assert(a and b, "jobs created")

local launched = fake.run_until(function()
	return #fake.calls_of("new") >= 2
end, 120000, 1000)
assert(launched, "both jobs launched")
fake.advance(2000)

local by_cwd = {}
for _, argv in ipairs(fake.calls_of("new")) do
	by_cwd[argv[7]] = argv
end
local function run_of(job)
	for _, r in ipairs(runner.inflight()) do
		if r.job_id == job.id then
			return r
		end
	end
end
local ra, rb = run_of(a), run_of(b)
assert(ra and rb, "both runs in flight")
local dir_a = "/d/runs/" .. a.id .. "/" .. ra.run_id
local dir_b = "/d/runs/" .. b.id .. "/" .. rb.run_id

-- staging calls: one per distinct local image, plugin-made destinations, sources resolved against prompts/ and ~
assert(#stage_calls == 3, "three staging spawns, got " .. #stage_calls)
assert(stage_calls[1].src == "/d/prompts/shot.png" and stage_calls[1].dst == dir_a .. "/images/1.png", "first: " .. stage_calls[1].dst)
assert(stage_calls[2].src == "/home/u/pics/b.JPG" and stage_calls[2].dst == dir_a .. "/images/2.jpg", "second: " .. stage_calls[2].dst)
assert(stage_calls[3].src == "/d/prompts/gone.png" and stage_calls[3].dst == dir_a .. "/images/3.png", "third: " .. stage_calls[3].dst)
assert(stage_calls[1].max == tostring(20 * 1024 * 1024), "20 MiB limit passed")
assert(stage_calls[1].script:find("exit 3", 1, true) and stage_calls[1].script:find('ln -f -- "$1" "$2"', 1, true), "stage script")
print("PASS staging spawns: 3 distinct sources, remote ignored, duplicate shared")

-- argv: exactly the two staged files after the prompt, before the fixed positional
local argv = by_cwd["/home/u/proj"]
local n = #argv
assert(argv[n] == "Run the scheduled job described in the attached file.", "fixed positional last")
assert(argv[n - 1] == "@" .. dir_a .. "/images/2.jpg", "second image: " .. tostring(argv[n - 1]))
assert(argv[n - 2] == "@" .. dir_a .. "/images/1.png", "first image: " .. tostring(argv[n - 2]))
assert(argv[n - 3] == "@" .. dir_a .. "/prompt.md", "prompt before the images: " .. tostring(argv[n - 3]))
local joined = table.concat(argv, " ")
assert(not joined:find("shot.png", 1, true) and not joined:find("gone.png", 1, true), "no user path in argv")
print("PASS argv: prompt.md then images/1.png, images/2.jpg")

-- snapshot: attached links rewritten (both references to shot.png), the missing and remote ones untouched
local snap = fake.read(dir_a .. "/prompt.md")
assert(snap:find("![a](images/1.png)", 1, true), "first link rewritten")
assert(snap:find("![b](images/2.jpg)", 1, true), "home link rewritten, extension lowercased")
assert(snap:find("![a2](<images/1.png>)", 1, true), "angle-bracket link rewritten, brackets kept")
assert(snap:find("![c](gone.png)", 1, true), "missing image link untouched")
assert(snap:find("![d](https://example.com/r.png)", 1, true), "remote link untouched")
print("PASS prompt.md snapshot rewritten")

-- preamble
local pre = fake.read(dir_a .. "/preamble.md")
local at = pre:find("- The images attached to the user's message come from the job's prompt, in the order it shows them (images/1.png, images/2.jpg).", 1, true)
local sk = pre:find("- The prompt refers to images that could not be attached: gone.png (not found). Say so in your final message if you needed them.", 1, true)
local result = pre:find("- End your final message with one line starting `RESULT:`", 1, true)
assert(at and sk and result and at < sk and sk < result, "preamble bullets in order before RESULT")
print("PASS preamble lists attached and skipped images")

-- run record
assert(ra.images and ra.images.attached == 2, "attached count")
assert(#ra.images.skipped == 1 and ra.images.skipped[1].name == "gone.png" and ra.images.skipped[1].why == "not found", "skipped list")
local noted = false
for _, note in ipairs(ra.notes or {}) do
	noted = noted or note == "images_skipped"
end
assert(noted, "images_skipped note")
print("PASS run.images = attached 2, skipped 1 (gone.png: not found); note images_skipped")

-- the job without images: nothing spawned for it, argv and files as before
local argv_b = by_cwd["/home/u/proj2"]
assert(argv_b[#argv_b - 1] == "@" .. dir_b .. "/prompt.md", "plain argv ends with prompt.md and the positional")
assert(rb.images == nil, "no image record on a plain run")
for _, note in ipairs(rb.notes or {}) do
	assert(note ~= "images_skipped", "no images_skipped note on a plain run")
end
assert(fake.read(dir_b .. "/prompt.md") == "Plain text, [a link](x.png) but no image", "plain prompt verbatim")
local pre_b = fake.read(dir_b .. "/preamble.md")
assert(not pre_b:find("images attached", 1, true) and not pre_b:find("could not be attached", 1, true), "no image bullets")
assert(#stage_calls == 3, "plain prompt spawned no sh")
print("PASS prompt without images: same argv, no staging, no record")

assert(#fake.errors == 0, "no error logs: " .. table.concat(fake.errors, "; "))
print("PASS no errors")
