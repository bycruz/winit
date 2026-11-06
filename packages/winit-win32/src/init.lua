local ffi = require("ffi")
local user32 = require("winapi.user32")
local kernel32 = require("winapi.kernel32")
local shell32 = require("winapi.shell32")
local Clipboard = require("winit-win32.clipboard")
local FileDialog = require("winit-win32.dialog")
local readDrop = require("winit-win32.drop")

--- Casts a ffi pointer to a lua number for use as a hash key.
---@param value ffi.cdata*
local function ffiptrToDouble(value)
	return tonumber(ffi.cast("intptr_t", value))
end

---@class winit-win32.Window: winit.Window
---@field display winapi.user32.ffi.HDC
---@field id ffi.cdata*
---@field hwnd winapi.user32.ffi.HWND
---@field currentCursor ffi.cdata*?
---@field width number
---@field height number
---@field shouldRedraw boolean?
local Win32Window = {}
Win32Window.__index = Win32Window

---@param eventLoop winit-win32.EventLoop
---@param width number
---@param height number
function Win32Window.new(eventLoop, width, height)
	---@cast eventLoop winit-win32.EventLoop
	-- We need to adjust the window size to account for borders and title bar
	-- This is specific to windows as the width and height when creating a window isn't just the client area.
	local rect = user32.Rect()
	rect.right = width
	rect.bottom = height

	if not user32.adjustWindowRect(rect, bit.bor(user32.WS.VISIBLE, user32.WS.OVERLAPPEDWINDOW), false) then
		error("Failed to adjust window rect: " .. kernel32.getLastErrorMessage())
	end

	local adjustedWidth = rect.right - rect.left
	local adjustedHeight = rect.bottom - rect.top

	local window = user32.createWindow(
		0,
		eventLoop.class.lpszClassName,
		"Title",
		bit.bor(user32.WS.VISIBLE, user32.WS.OVERLAPPEDWINDOW),
		0x80000000,
		0x80000000,
		adjustedWidth,
		adjustedHeight,
		nil,
		nil,
		eventLoop.class.hInstance,
		nil
	)

	if window == nil then
		error("Failed to create window: " .. kernel32.getLastErrorMessage())
	end

	-- A window is a place files may be dropped on, which is said rather than assumed: until it
	-- is, the shell will not send a window the drops it is under.
	shell32.dragAcceptFiles(window, true)

	local made = setmetatable({ hwnd = window, id = ffiptrToDouble(window), width = width,
		height = height }, Win32Window)
	made.cursors = { text = true}
	return made
end

---@type table<string, integer>
local cursors = {
	pointer = user32.IDC.ARROW,
	hand2 = user32.IDC.HAND,
	text = ffi.cast("LPCSTR", 32513), -- IDC_IBEAM
}

---@param shape "pointer" | "hand2" | "text"
---@return nil
function Win32Window:setCursor(shape)
	local idc = assert(cursors[shape], "Unknown cursor shape: " .. tostring(shape))
	local cursor = user32.loadCursor(nil, ffi.cast("LPCSTR", idc))
	user32.setCursor(cursor)
	self.currentCursor = cursor
	return nil
end

function Win32Window:resetCursor()
	self:setCursor("pointer")
end

---@param title string
---@return nil
function Win32Window:setTitle(title)
	user32.setWindowText(self.hwnd, title)
	return nil
end


function Win32Window:destroy()
	user32.destroyWindow(self.hwnd)
end

---@class winit-win32.EventLoop: winit.EventLoop
---@field windows table<string, winit-win32.Window>
---@field class winapi.user32.ffi.WNDCLASSEXA
---@field isActive boolean
---@field currentMode "poll" | "wait"
---@field handler winit.EventManager
---@field callback winit.EventHandler
local Win32EventLoop = {}
Win32EventLoop.__index = Win32EventLoop

-- A window class belongs to the process rather than to the loop that made it, and the system
-- refuses a second one under a name already taken. What each loop registers is a name of its
-- own, so that making another one -- a second loop in the same program, or a suite that runs
-- several of them -- is always possible: what a class carries is the window procedure its
-- windows are dispatched to, and that is the loop's own.
local classCount = 0

local ERROR_CLASS_ALREADY_EXISTS = 1410

-- What one notch of a wheel turns by. A finer wheel or a precision touchpad reports a fraction of
-- it, which is passed on as a fraction of a notch.
local WHEEL_DELTA = 120

-- What a key is, which windows answers from the virtual key code it gives, and what it types, which
-- is the keyboard layout's answer and comes from the system below: a key's name is the key -- the
-- letter a binding is written against -- and its text is the character it produced, case and all.
ffi.cdef [[
	int GetKeyboardState(uint8_t *lpKeyState);
	int ToUnicodeEx(unsigned int wVirtKey, unsigned int wScanCode, const uint8_t *lpKeyState,
		uint16_t *pwszBuff, int cchBuff, unsigned int wFlags, void *dwhkl);
	void *GetKeyboardLayout(unsigned long idThread);
]]

-- Held rather than loaded where it is called: a library handle the collector lets go of unloads the
-- dll behind it, and what this module holds of it then points into nothing.
local user32Library = ffi.load("user32")

-- The keys this platform names, by virtual key code. A letter, a digit and a punctuation key are
-- named after what they are on a keyboard rather than after what the layout makes of them, which is
-- what a binding is written against; the table below fills the letters and digits in.
local KEY_NAMES = {
	[0x08] = "backspace",
	[0x09] = "tab",
	[0x0D] = "return",
	[0x10] = "left-shift",
	[0x11] = "left-ctrl",
	[0x12] = "left-alt",
	[0x13] = "pause",
	[0x14] = "caps-lock",
	[0x1B] = "escape",
	[0x20] = "space",
	[0x21] = "page-up",
	[0x22] = "page-down",
	[0x23] = "end",
	[0x24] = "home",
	[0x25] = "left",
	[0x26] = "up",
	[0x27] = "right",
	[0x28] = "down",
	[0x2C] = "print-screen",
	[0x2D] = "insert",
	[0x2E] = "delete",
	[0x5B] = "left-super",
	[0x5C] = "right-super",
	[0x5D] = "menu",
	[0x90] = "num-lock",
	[0x91] = "scroll-lock",
	[0x92] = "num-equal",
	[0x60] = "num-0",
	[0x61] = "num-1",
	[0x62] = "num-2",
	[0x63] = "num-3",
	[0x64] = "num-4",
	[0x65] = "num-5",
	[0x66] = "num-6",
	[0x67] = "num-7",
	[0x68] = "num-8",
	[0x69] = "num-9",
	[0x6A] = "num-multiply",
	[0x6B] = "num-add",
	[0x6C] = "num-separator",
	[0x6D] = "num-subtract",
	[0x6E] = "num-decimal",
	[0x6F] = "num-divide",
	[0xBA] = ";",
	[0xBB] = "=",
	[0xBC] = ",",
	[0xBD] = "-",
	[0xBE] = ".",
	[0xBF] = "/",
	[0xC0] = "`",
	[0xDB] = "[",
	[0xDC] = "\\",
	[0xDD] = "]",
	[0xDE] = "'",
	[0xE2] = "\\",
}

for at = 0, 9 do
	KEY_NAMES[0x30 + at] = tostring(at)
end

for at = 0, 25 do
	KEY_NAMES[0x41 + at] = string.char(0x61 + at)
end

for at = 1, 24 do
	KEY_NAMES[0x6F + at] = "f" .. at
end

local KEYBOARD_STATE = ffi.new("uint8_t[256]")
local TYPED_BUFFER = ffi.new("uint16_t[8]")

--- Whether a key is down now. What windows answers with is set in its top bit, and what LuaJIT reads
--- out of the sixteenth is a small number: both are asked for the same ones and the same zeroes.
---@param virtual number
---@return boolean
local function isDown(virtual)
	return bit.band(tonumber(user32.getKeyState(virtual)), 0x8000) ~= 0
end

--- What is held down, as the app is told it with every key: the modifiers a binding and a field are
--- decided by.
---@return winit.KeyModifiers
local function modifiersNow()
	return {
		shift = isDown(0x10),
		ctrl = isDown(0x11),
		alt = isDown(0x12),
		super = isDown(0x5B) or isDown(0x5C),
		lock = bit.band(tonumber(user32.getKeyState(0x14)), 1) ~= 0,
	}
end

--- UTF-16 as UTF-8, which is what the rest of winit carries text in.
---@param units uint16_t[]
---@param count number
---@return string
local function utf8Of(units, count)
	local out = {}

	for at = 0, count - 1 do
		local unit = units[at]
		local codepoint = unit

		if unit >= 0xD800 and unit <= 0xDBFF and at + 1 < count then
			local low = units[at + 1]

			codepoint = 0x10000 + (unit - 0xD800) * 0x400 + (low - 0xDC00)
			at = at + 1
		end

		if codepoint < 0x80 then
			out[#out + 1] = string.char(codepoint)
		elseif codepoint < 0x800 then
			out[#out + 1] = string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
		elseif codepoint < 0x10000 then
			out[#out + 1] = string.char(0xE0 + math.floor(codepoint / 0x1000),
				0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
		else
			out[#out + 1] = string.char(0xF0 + math.floor(codepoint / 0x40000),
				0x80 + math.floor(codepoint / 0x1000) % 0x40, 0x80 + math.floor(codepoint / 0x40) % 0x40,
				0x80 + codepoint % 0x40)
		end
	end

	return table.concat(out)
end

--- What a key typed, where it typed anything: the layout's answer for this key with the modifiers
--- that are held, which is what makes shift and 1 an exclamation mark and a dead key wait for the one
--- after it. Nought where the key types nothing of its own -- an arrow, a held control.
---@param virtual number
---@param scan number
---@return string?
local function typedNow(virtual, scan)
	if user32Library.GetKeyboardState(KEYBOARD_STATE) == 0 then
		return nil
	end

	-- The last is the flag that keeps a dead key untouched by being asked: the accent it is waiting
	-- to put on the next letter is still waiting after this.
	local count = user32Library.ToUnicodeEx(virtual, scan, KEYBOARD_STATE, TYPED_BUFFER, 8, 1,
		user32Library.GetKeyboardLayout(0))

	if count <= 0 then
		return nil
	end

	local text = utf8Of(TYPED_BUFFER, count)

	return text ~= "" and text or nil
end

--- The name a key is told by: what it is on a keyboard, and failing that what it typed, which is
--- how a key a layout puts somewhere else -- the letters of one that is not qwerty -- is named.
---@param virtual number
---@param text string?
---@return string?
local function keyName(virtual, text)
	local named = KEY_NAMES[virtual]

	if named ~= nil then
		return named
	end

	if text ~= nil then
		return text:lower()
	end

	return nil
end

--- How far a wheel message turned, in notches: the signed high word of its wParam.
---@param wParam winapi.user32.ffi.WPARAM
---@return number
local function wheelNotches(wParam)
	return tonumber(ffi.cast("short", user32.HIWORD(wParam))) / WHEEL_DELTA
end

---@param loop winit-win32.EventLoop
---@param callback winit.EventHandler
local function deliverRedraws(loop, callback)
	for _, window in pairs(loop.windows) do
		if window.shouldRedraw then
			window.shouldRedraw = false
			callback({ name = "redraw", window = window }, loop.handler)
		end
	end
end

function Win32EventLoop.new()
	local hInstance = kernel32.getModuleHandle(nil)
	if hInstance == nil then
		error("Failed to get module handle: " .. kernel32.getLastErrorMessage())
	end

	local class = user32.WndClassEx()
	local self = setmetatable({ class = class, windows = {} }, Win32EventLoop)

	classCount = classCount + 1
	class.lpszClassName = "winit-window-" .. classCount
	class.lpfnWndProc = ffi.cast("WNDPROC", user32.WndProc(function(hwnd, msg, wParam, lParam)
		if not self.callback then
			return user32.defWindowProc(hwnd, msg, wParam, lParam)
		end

		local window = self.windows[tostring(ffiptrToDouble(hwnd))]
		if not window then
			return user32.defWindowProc(hwnd, msg, wParam, lParam)
		end

		if msg == user32.WM.ERASEBKGND then
			-- Nothing is erased behind a frame: what a window of this is, is what the app draws in
			-- it, and filling it with the system's own colour first is what a white flash under a
			-- frame being resized is.
			return 1
		elseif msg == user32.WM.PAINT then
			self.callback({ name = "redraw", window = window }, self.handler)
			return 0
		elseif msg == user32.WM.SIZE then
			if window then
				window.width = assert(tonumber(user32.LOWORD(lParam)))
				window.height = assert(tonumber(user32.HIWORD(lParam)))
			end

			self.callback({ name = "resize", window = window }, self.handler)

			deliverRedraws(self, self.callback)
			return 0
		elseif msg == 0x0018 then -- WM_SHOWWINDOW
			if user32.LOWORD(wParam) ~= 0 then
				self.callback({ window = window, name = "map" }, self.handler)
			else
				self.callback({ window = window, name = "unmap" }, self.handler)
			end

			return 0
		elseif msg == user32.WM.MOUSEMOVE then
			local x = user32.GET_X_LPARAM(lParam)
			local y = user32.GET_Y_LPARAM(lParam)
			self.callback({ window = window, name = "mouseMove", x = x, y = y }, self.handler)
			return 0
		elseif msg == user32.WM.LBUTTONDOWN then
			local x = user32.GET_X_LPARAM(lParam)
			local y = user32.GET_Y_LPARAM(lParam)
			self.callback({ window = window, name = "mousePress", x = x, y = y }, self.handler)
			return 0
		elseif msg == user32.WM.LBUTTONUP then
			local x = user32.GET_X_LPARAM(lParam)
			local y = user32.GET_Y_LPARAM(lParam)
			self.callback({ window = window, name = "mouseRelease", x = x, y = y }, self.handler)
			return 0
		elseif msg == user32.WM.MOUSEWHEEL then
			-- Turned away from the user is positive here and up a page, where a scroll event counts
			-- down the page as positive -- one notch is one line, as the other platforms report it.
			self.callback({ window = window, name = "mouseScroll", dx = 0, dy = -wheelNotches(wParam) }, self.handler)
			return 0
		elseif msg == user32.WM.MOUSEHWHEEL then
			-- A tilt to the right is positive, which is the direction a scroll event counts too.
			self.callback({ window = window, name = "mouseScroll", dx = wheelNotches(wParam), dy = 0 }, self.handler)
			return 0
		elseif msg == user32.WM.CLOSE then
			self.callback({ window = window, name = "windowClose" }, self.handler)
			return 0
		elseif msg == user32.WM.KEYDOWN or msg == user32.WM.SYSKEYDOWN then
			-- The virtual key code is the low byte of wParam; what the message says of the press is in
			-- lParam: the scan code the layout is asked with, and whether the keyboard is repeating a
			-- key it has held. A press that types nothing of its own -- an arrow, a control -- is
			-- named by the table, and one that does is named by what it typed.
			local virtual = tonumber(bit.band(wParam, 0xFF))
			local scan = tonumber(bit.band(bit.rshift(tonumber(lParam), 16), 0xFF))
			local repeated = bit.band(tonumber(lParam), 0x40000000) ~= 0
			local modifiers = modifiersNow()
			local text = typedNow(virtual, scan)
			local key = keyName(virtual, text)

			if key ~= nil then
				self.callback({
					window = window,
					name = "keyPress",
					key = key,
					modifiers = modifiers,
					text = text,
					repeated = repeated and true or nil,
				}, self.handler)
			end

			-- A system key is still the system's: alt and F4 close the window, and a key that is
			-- taken and not answered would be one nothing ever handles.
			if msg == user32.WM.SYSKEYDOWN then
				return user32.defWindowProc(hwnd, msg, wParam, lParam)
			end

			return 0
		elseif msg == user32.WM.KEYUP or msg == user32.WM.SYSKEYUP then
			local virtual = tonumber(bit.band(wParam, 0xFF))
			local text = typedNow(virtual, tonumber(bit.band(bit.rshift(tonumber(lParam), 16), 0xFF)))
			local key = keyName(virtual, text)

			if key ~= nil then
				self.callback({ window = window, name = "keyRelease", key = key, modifiers = modifiersNow() },
					self.handler)
			end

			if msg == user32.WM.SYSKEYUP then
				return user32.defWindowProc(hwnd, msg, wParam, lParam)
			end

			return 0
		elseif msg == user32.WM.DROPFILES then
			-- What a drag carried, which the shell hands over as one thing to read the files out
			-- of and be done with -- so what is passed on is the paths, and the drop itself is
			-- finished with inside the read.
			local paths, x, y = readDrop(ffi.cast("HDROP", wParam))
			self.callback({ window = window, name = "fileDrop", paths = paths, x = x, y = y }, self.handler)
			return 0
		end

		return user32.defWindowProc(hwnd, msg, wParam, lParam)
	end))
	class.hCursor = user32.loadCursor(nil, ffi.cast("LPCSTR", user32.IDC.ARROW))
	class.hIcon = user32.loadIcon(nil, ffi.cast("LPCSTR", user32.IDI.APPLICATION))

	class.hbrBackground = ffi.cast("void*", nil)
	class.style = bit.bor(user32.CS.HREDRAW, user32.CS.VREDRAW)

	class.hInstance = hInstance

	-- The names already taken are stepped past rather than counted from this state's own
	-- beginning: a class belongs to the process, and a second Lua state -- which is what every
	-- test file of a suite is -- starts counting again from nothing.
	local registered = false
	for step = 0, 64 do
		class.lpszClassName = ("winit-window-%d"):format(classCount + step)

		if user32.registerClass(class) ~= 0 then
			classCount = classCount + step + 1
			registered = true
			break
		end

		if kernel32.getLastError() ~= ERROR_CLASS_ALREADY_EXISTS then
			break
		end
	end

	if not registered then
		error("Failed to register window class: " .. kernel32.getLastErrorMessage())
	end

	local handler = {}
	do
		function handler.exit(_)
			self.isActive = false
		end

		---@param mode "poll" | "wait"
		function handler.setMode(_, mode)
			self.currentMode = mode
		end

		--- A wait with a deadline is not in this backend: a screen with something to do on its own
		--- is woken by the events it is given and no earlier.
		---@param seconds number?
		function handler.setTimeout(_, seconds) end

		---@param window winit-win32.Window
		function handler.requestRedraw(_, window)
			window.shouldRedraw = true
		end

		---@param window winit.Window
		function handler.close(_, window)
			self:close(window)
		end
	end

	self.handler = handler

	return self
end

---@param window winit.Window
---@return nil
function Win32EventLoop:register(window)
	-- A window is looked up by what the platform calls it, which on this one is the handle as
	-- a number: what the loop keeps them under is the same thing the X11 backend keeps them
	-- under -- a string -- so that a program reading `windows` sees one shape either way.
	self.windows[tostring(window.id)] = window
	return nil
end

---@param window winit.Window
function Win32EventLoop:close(window)
	window:destroy()
	self.windows[tostring(window.id)] = nil
end

---@param callback winit.EventHandler
function Win32EventLoop:run(callback)
	self.isActive = true
	self.currentMode = "poll"
	self.callback = function(event, handler)
		local ok, err = xpcall(callback, debug.traceback, event, handler)
		if not ok then
			print("Error in event loop callback: " .. tostring(err))
			os.exit(1)
		end
	end

	for _, window in pairs(self.windows) do
		self.callback({ name = "create", window = window }, self.handler)
	end

	local msg = user32.Msg()
	while self.isActive do
		if self.currentMode == "poll" then
			if user32.peekMessage(msg, nil, 0, 0, user32.PM.REMOVE) then
				user32.translateMessage(msg)
				user32.dispatchMessage(msg)
			end
		else
			user32.getMessage(msg, nil, 0, 0)
			user32.translateMessage(msg)
			user32.dispatchMessage(msg)
		end

		deliverRedraws(self, callback)

		callback({ name = "aboutToWait" }, self.handler)
	end

	for _, window in pairs(self.windows) do
		self:close(window)
	end
end

---@param hInstance ffi.cdata*
function Win32EventLoop:cleanup(hInstance)
	user32.unregisterClass(self.class.lpszClassName, hInstance)
end

return { Window = Win32Window, EventLoop = Win32EventLoop, Clipboard = Clipboard,
	FileDialog = FileDialog }
