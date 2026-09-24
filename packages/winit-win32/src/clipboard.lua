local ffi = require("ffi")
local kernel32 = require("winapi.kernel32")
local user32 = require("winapi.user32")

--- How many times a clipboard another program is holding is tried again, and how long between
--- tries, in milliseconds. The clipboard is one thing the whole system shares and one program
--- holds it at a time, so finding it taken is a moment rather than a refusal -- a paste that
--- gave up on the first try would fail for no reason a person could see.
local OPEN_ATTEMPTS = 10
local OPEN_RETRY_MS = 10

---@class winit-win32.Clipboard: winit.Clipboard
local Clipboard = {}
Clipboard.__index = Clipboard

---@param _eventLoop winit.EventLoop # the loop belongs to the X11 side of this; here it is only symmetry
---@return winit-win32.Clipboard
function Clipboard.new(_eventLoop)
	return setmetatable({}, Clipboard)
end

--- Takes the clipboard for the length of one look at it, waiting out whoever else is in it.
---@return boolean
local function open()
	for _ = 1, OPEN_ATTEMPTS do
		if user32.openClipboard(nil) then
			return true
		end

		kernel32.sleep(OPEN_RETRY_MS)
	end

	return false
end

--- Offers text to the rest of the system, which keeps it after this program is gone: what is
--- handed over is a block of the system's own memory, and the clipboard takes it from there.
---@param text string
function Clipboard:setText(text)
	local wide = kernel32.utf8ToWide(text)
	if wide == nil then
		return
	end

	local units = 0
	while wide[units] ~= 0 do
		units = units + 1
	end

	-- the terminator the system reads the text out to, which the string itself does not hold
	local bytes = (units + 1) * 2

	if not open() then
		return
	end

	user32.emptyClipboard()

	local handle = kernel32.globalAlloc(kernel32.GMEM.MOVEABLE, bytes)
	if handle ~= nil then
		local pointer = kernel32.globalLock(handle)
		if pointer ~= nil then
			ffi.copy(pointer, wide, bytes)
			kernel32.globalUnlock(handle)
		end

		-- safety: once the clipboard has it, the memory is the system's to free, and freeing it
		-- here would leave the clipboard pointing at nothing. It only stays ours if it was
		-- refused.
		if not user32.setClipboardData(user32.CF.UNICODETEXT, handle) then
			kernel32.globalFree(handle)
		end
	end

	user32.closeClipboard()
end

--- Empties the clipboard, which is the system's to do rather than something to be overwritten
--- with nothing.
function Clipboard:clear()
	if not open() then
		return
	end

	user32.emptyClipboard()
	user32.closeClipboard()
end

--- What the clipboard holds, or nothing when what it holds is not text.
---@return string?
function Clipboard:getText()
	if not user32.isClipboardFormatAvailable(user32.CF.UNICODETEXT) then
		return nil
	end

	if not open() then
		return nil
	end

	local handle = user32.getClipboardData(user32.CF.UNICODETEXT)
	local pointer = handle ~= nil and kernel32.globalLock(handle) or nil
	local text = nil

	if pointer ~= nil then
		text = kernel32.wideToUtf8(pointer)
		kernel32.globalUnlock(handle)
	end

	user32.closeClipboard()

	return text
end

return Clipboard
