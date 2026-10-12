-- lib/images.luau: reference finding, destination resolving, extension check, link rewriting.
local images = __mods.images

local function dests(text)
  local out = {}
  for _, r in ipairs(images.refs(text)) do
    -- the byte range must hold the raw destination text
    assert(text:sub(r.s, r.e) ~= "", "range is non-empty")
    table.insert(out, r.dest)
  end
  return out
end
local function show(label, text, want)
  local got = dests(text)
  assert(table.concat(got, "|") == table.concat(want, "|"), label .. ": got [" .. table.concat(got, "|") .. "]")
  print(string.format("refs %s => [%s]", label, table.concat(got, "|")))
end

show("inline", "see ![shot](a.png) now", { "a.png" })
show("alt with brackets", "![a [b] c](dir/x.jpg)", { "dir/x.jpg" })
show("angle with spaces", "![x](<my pics/a b.png>)", { "my pics/a b.png" })
show("double-quote title", '![x](a.png "the title")', { "a.png" })
show("single-quote title", "![x](a.png 'the title')", { "a.png" })
show("paren title", "![x](a.png (the title))", { "a.png" })
show("angle and title", '![x](<a b.png> "t")', { "a b.png" })
show("percent-encoded", "![x](my%20pics/a%20b.png)", { "my pics/a b.png" })
show("html double quotes", 'text <img src="a.png" width="10"> more', { "a.png" })
show("html single quotes", "<img alt='x' src='b.webp'/>", { "b.webp" })
show("html data-src ignored", '<img data-src="a.png">', {})
show("multiple", "![a](1.png)\ntext ![b](2.gif) and <img src=\"3.bmp\">\n![c](1.png)", { "1.png", "2.gif", "3.bmp", "1.png" })
show("link not image", "[x](y.png) and [y](z)", {})
show("fenced backticks", "```\n![a](in-fence.png)\n```\n![b](out.png)", { "out.png" })
show("fenced tildes", "~~~md\n![a](in-fence.png)\n~~~\n![b](out.png)", { "out.png" })
show("longer fence", "````\n```\n![a](in.png)\n```\n![z](still-in.png)\n````\n![b](out.png)", { "out.png" })
show("inline code", "`![a](code.png)` ![b](out.png)", { "out.png" })
show("double-backtick code", "``x ` ![a](code.png)`` ![b](out.png)", { "out.png" })
show("unmatched backtick", "a ` ![b](out.png)", { "out.png" })
show("url", "![x](https://example.com/a.png)", { "https://example.com/a.png" })
show("unclosed", "![x](a.png", {})
show("empty", "![x]()", {})

local text = "a ![x](<p q.png>) b ![y](z.png \"t\")"
local refs = images.refs(text)
assert(text:sub(refs[1].s, refs[1].e) == "p q.png" and text:sub(refs[2].s, refs[2].e) == "z.png", "ranges are the raw destination")
print("refs ranges => " .. text:sub(refs[1].s, refs[1].e) .. "|" .. text:sub(refs[2].s, refs[2].e))
local html = 'x <img src="a%20b.png"> y'
local hr = images.refs(html)[1]
assert(html:sub(hr.s, hr.e) == "a%20b.png" and hr.dest == "a b.png", "html range is inside the quotes")
print("refs html range => " .. html:sub(hr.s, hr.e) .. " (" .. hr.dest .. ")")

local base, home = "/d/prompts", "/home/u"
local function res(dest, h)
  local r = images.resolve(dest, base, h == nil and home or (h ~= false and h or nil))
  print(string.format("resolve %q => %s", dest, tostring(r)))
  return r
end
assert(res("a.png") == "/d/prompts/a.png")
assert(res("./a.png") == "/d/prompts/a.png")
assert(res("sub//x/./a.png") == "/d/prompts/sub/x/a.png")
assert(res("../a.png") == "/d/a.png")
assert(res("../../../../a.png") == "/a.png")
assert(res("~/pics/a.png") == "/home/u/pics/a.png")
assert(res("~/pics/a.png", false) == nil)
assert(res("~/pics/a.png", "") == nil)
assert(res("/abs/dir/../a.png") == "/abs/a.png")
assert(res("/abs/a.png/") == "/abs/a.png")
assert(res("file:///abs/a.png") == "/abs/a.png")
assert(res("file://localhost/abs/a.png") == "/abs/a.png")
assert(res("https://example.com/a.png") == nil)
assert(res("http://example.com/a.png") == nil)
assert(res("data:image/png;base64,AAAA") == nil)
assert(res("#anchor") == nil)
assert(res("") == nil)
assert(res("/") == "/")

local function img(path)
  local v = images.is_image(path)
  print(string.format("is_image %s => %s", path, tostring(v)))
  return v
end
assert(img("/x/a.png") and img("a.JPG") and img("a.jpeg") and img("a.Gif") and img("a.webp") and img("a.bmp"))
assert(not img("a.svg") and not img("a.txt") and not img("png") and not img("/x/dir.png/file"))

local subs = { { s = 11, e = 15, with = "images/2.png" }, { s = 3, e = 5, with = "images/1.png" } }
local rewritten = images.rewrite("0123456789ABCDEFGHIJ", subs)
assert(rewritten == "01images/1.png56789images/2.pngFGHIJ", rewritten)
print("rewrite unsorted => " .. rewritten)
assert(images.rewrite("abc", {}) == "abc")
print("rewrite none => abc")
local doc = "![a](<p q.png>) and ![b](z.png)"
local rs = images.refs(doc)
local out = images.rewrite(doc, { { s = rs[2].s, e = rs[2].e, with = "images/2.png" }, { s = rs[1].s, e = rs[1].e, with = "images/1.png" } })
assert(out == "![a](<images/1.png>) and ![b](images/2.png)", out)
print("rewrite doc => " .. out)
return 0
