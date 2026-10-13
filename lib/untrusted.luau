--!strict
-- lib/untrusted.luau : cleaning and fencing of collected text that is handed to a model as data (pure).
local untrusted = {}

-- Removes terminal escapes, control characters and bidi/zero-width marks from collected text.
function untrusted.clean(s: string): string
	s = s:gsub("\27%[[%d;?]*[%a]", "")
	s = s:gsub("\r\n", "\n")
	s = s:gsub("[\0-\8\11-\31\127]", " ")
	s = s:gsub("\xE2\x80[\xAA-\xAE]", "")
	s = s:gsub("\xE2\x81[\xA6-\xA9]", "")
	s = s:gsub("\xE2\x80[\x8B-\x8F]", "")
	s = s:gsub("\xEF\xBB\xBF", "")
	return s
end

-- BEGIN/END marker lines around one block of untrusted text.
function untrusted.fence(nonce: string, name: string, source: string, text: string): string
	return string.format("----- BEGIN UNTRUSTED DATA %s [name=%s source=%s] -----", nonce, name, source)
		.. "\n"
		.. text
		.. "\n"
		.. string.format("----- END UNTRUSTED DATA %s -----", nonce)
end

return untrusted
