-- The macOS backend: what the Lua half of winit asks of a platform, said in terms of the shim
-- beside this file. See `src/shim.m`, which is where the window, the events and the clipboard
-- actually live, and which is built by this package's build script.

local ffi = require("ffi")

ffi.cdef([[
typedef struct {
	int type;
	int window;
	double x, y;
	double width, height;
	double dx, dy;
	int button;
	unsigned short keycode;
	unsigned int modifiers;
	int repeated;
	char text[64];
	char paths[8192];
} winit_macos_event;

int winit_macos_init(void);
int winit_macos_window_create(int width, int height, const char *title);
void winit_macos_window_destroy(int handle);
void winit_macos_window_set_title(int handle, const char *title);
void winit_macos_window_size(int handle, int *width, int *height);
void *winit_macos_window_view(int handle);
void winit_macos_window_set_cursor(int handle, int shape);
void winit_macos_window_reset_cursor(int handle);
void winit_macos_window_set_grab(int handle, int mode);
int winit_macos_next_event(winit_macos_event *out, double timeout);
int winit_macos_clipboard_get(char *buffer, int capacity);
int winit_macos_clipboard_set(const char *text);
int winit_macos_clipboard_clear(void);
]])

--- The shim, which is loaded once for a whole process however many Lua states that process holds.
---
--- What the library defines is a window class, and a class is the runtime's by name: loading a
--- second copy of the library -- which is what a monorepo's suite of tests is, every test file a
--- state of its own with its own package directory -- leaves the runtime answering with the first
--- copy's methods while the second copy holds its own state, so the windows a second copy makes
--- are ones the first copy's callbacks hear about and the second copy's loop waits on forever.
---
--- So the first state loads it for the whole process to see, and every state after that finds it
--- again rather than loading a copy: what is asked is the default namespace, which is the one the
--- C runtime resolves a symbol in when it is not asked for a library in particular.
---@return ffi.namespace*
local function loadShim()
	local already = pcall(function()
		return ffi.C.winit_macos_init
	end)

	if already then
		return ffi.C
	end

	-- Where this file came from, which is where the library was built beside it: a program that is
	-- compiled is one whose files are not where they were built, and what travels with them is the
	-- library under the same name, in the same place relative to this file.
	local source = debug.getinfo(1, "S").source
	local directory = source:match("^@(.*)[/\\][^/\\]*$")

	if not directory then
		error("winit-macos could not work out where its shim is")
	end

	local loaded, shim = pcall(ffi.load, directory .. "/shim.so", true)

	if not loaded then
		error("winit-macos was installed without its shim (" .. tostring(shim) .. ")")
	end

	return shim
end

local shim = loadShim()

--- What the shim says an event is, which is the numbering both halves agree on.
local Event = {
	windowClose = 1,
	windowResize = 2,
	focusIn = 3,
	focusOut = 4,
	mouseMove = 5,
	mousePress = 6,
	mouseRelease = 7,
	mouseScroll = 8,
	keyPress = 9,
	keyRelease = 10,
	fileDrop = 11
}

--- The keys a mac keyboard has, by the number this platform gives them. What a press carries is
--- where the key sits on the board rather than which letter it makes, so what a program is handed
--- is the key's own name and the letter is left to the text beside it: see `textFor`.
local keyNames = {
	[0] = "a", [1] = "s", [2] = "d", [3] = "f", [4] = "h", [5] = "g", [6] = "z", [7] = "x",
	[8] = "c", [9] = "v", [11] = "b", [12] = "q", [13] = "w", [14] = "e", [15] = "r", [16] = "y",
	[17] = "t", [18] = "1", [19] = "2", [20] = "3", [21] = "4", [22] = "6", [23] = "5", [24] = "=",
	[25] = "9", [26] = "7", [27] = "-", [28] = "8", [29] = "0", [30] = "]", [31] = "o", [32] = "u",
	[33] = "[", [34] = "i", [35] = "p", [36] = "return", [37] = "l", [38] = "j", [39] = "'",
	[40] = "k", [41] = ";", [42] = "\\", [43] = ",", [44] = "/", [45] = "n", [46] = "m", [47] = ".",
	[48] = "tab", [49] = "space", [50] = "`", [51] = "backspace", [53] = "escape",
	[54] = "right-super", [55] = "left-super", [56] = "left-shift", [57] = "caps-lock",
	[58] = "left-alt", [59] = "left-ctrl", [60] = "right-shift", [61] = "right-alt",
	[62] = "right-ctrl",
	[96] = "f5", [97] = "f6", [98] = "f7", [99] = "f3", [100] = "f8", [101] = "f9",
	[103] = "f11", [109] = "f10", [111] = "f12",
	[114] = "insert", [115] = "home", [116] = "page-up", [117] = "delete", [118] = "f4",
	[119] = "end", [120] = "f2", [121] = "page-down", [122] = "f1",
	[123] = "left", [124] = "right", [125] = "down", [126] = "up"
}

--- What a key types, when it types anything a person would read. A key held with something else
--- types a control character, and the arrows and the function keys are not characters at all: this
--- platform says them in the private use area, which is one of the ranges a program never shows.
---@param characters string
---@return string?
local function textFor(characters)
	if #characters == 0 then
		return nil
	end

	local first = characters:byte(1)
	local second = characters:byte(2)

	if first < 0x20 or first == 0x7f then
		return nil
	end

	if first == 0xef and second and second >= 0x9c and second <= 0xa3 then
		return nil
	end

	return characters
end

--- What this platform calls each modifier, by the bit it sets in an event's flags. What is asked of
--- the keyboard is which of them are held, which is the same question the other backends answer
--- out of their own platforms' state.
local modifierBits = {
	shift = 1 << 17,
	lock = 1 << 16,
	ctrl = 1 << 18,
	alt = 1 << 19,
	super = 1 << 20
}

---@param flags number
---@return winit.KeyModifiers
local function modifiersOf(flags)
	return {
		shift = bit.band(flags, modifierBits.shift) ~= 0,
		lock = bit.band(flags, modifierBits.lock) ~= 0,
		ctrl = bit.band(flags, modifierBits.ctrl) ~= 0,
		alt = bit.band(flags, modifierBits.alt) ~= 0,
		super = bit.band(flags, modifierBits.super) ~= 0
	}
end

--- The buttons this platform numbers, told as the ones a program is handed: the middle button sits
--- between the other two here rather than after them.
local mouseButtons = { [0] = 1, [1] = 3, [2] = 2 }

local cursorShapes = { pointer = 0, hand2 = 1 }
local cursorGrabs = { none = 0, contain = 1, locked = 2 }

---@class winit-macos.Window: winit.Window
---@field cursorGrab winit.CursorGrab?
local MacWindow = {}
MacWindow.__index = MacWindow

---@param eventLoop winit-macos.EventLoop
---@param width number
---@param height number
---@return winit-macos.Window
function MacWindow.new(eventLoop, width, height)
	local id = shim.winit_macos_window_create(width, height, "Title")

	if id == 0 then
		error("Failed to create window: this machine has no screen to put one on")
	end

	return setmetatable({ id = id, width = width, height = height }, MacWindow)
end

---@param title string
function MacWindow:setTitle(title)
	shim.winit_macos_window_set_title(self.id, title)
end

---@param shape string
function MacWindow:setCursor(shape)
	local identified = cursorShapes[shape]

	if not identified then
		error("Unknown cursor shape: " .. tostring(shape))
	end

	shim.winit_macos_window_set_cursor(self.id, identified)
end

function MacWindow:resetCursor()
	shim.winit_macos_window_reset_cursor(self.id)
end

---@param mode winit.CursorGrab
function MacWindow:setCursorGrab(mode)
	-- safety: the same mode arriving again changes nothing, and a program that asks for the pointer
	-- to be held every frame is one asking the pointer to be put back where it is.
	if mode == self.cursorGrab then
		return
	end

	local identified = cursorGrabs[mode]

	if not identified then
		error("Unknown cursor grab mode: " .. tostring(mode))
	end

	shim.winit_macos_window_set_grab(self.id, identified)
	self.cursorGrab = mode
end

function MacWindow:destroy()
	shim.winit_macos_window_destroy(self.id)
end

--- The view this window draws in, which is what a renderer makes its context out of.
---@return ffi.cdata*
function MacWindow:nativeView()
	return shim.winit_macos_window_view(self.id)
end

---@class winit-macos.EventLoop: winit.EventLoop
---@field isActive boolean
---@field currentMode "poll" | "wait"
---@field timeout number?
---@field event winit_macos_event
local MacEventLoop = {}
MacEventLoop.__index = MacEventLoop

---@return winit-macos.EventLoop
function MacEventLoop.new()
	if shim.winit_macos_init() ~= 0 then
		error("Failed to open a connection to the window server")
	end

	local self = setmetatable({ windows = {}, event = ffi.new("winit_macos_event") }, MacEventLoop)

	---@type winit.EventManager
	local handler = {}
	do
		function handler.exit(_)
			self.isActive = false
		end

		function handler.setMode(_, mode)
			self.currentMode = mode
		end

		--- How long the next wait may last, in seconds, or nothing to wait out an event with no end
		--- to it. One wait: a deadline is what a screen with something to do on its own asks for,
		--- and it asks again for the next one. See `winit.EventManager:setTimeout`.
		---@param seconds number?
		function handler.setTimeout(_, seconds)
			self.timeout = seconds
		end

		function handler.requestRedraw(_, window)
			window.shouldRedraw = true
		end

		function handler.close(_, window)
			self:close(window)
		end
	end

	self.handler = handler

	return self
end

---@param window winit-macos.Window
function MacEventLoop:register(window)
	-- Windows are kept under the id the platform gives them, as a string: what a program reading
	-- `windows` sees is one shape whichever backend is behind it.
	self.windows[tostring(window.id)] = window
end

---@param window winit-macos.Window
function MacEventLoop:close(window)
	window:destroy()
	self.windows[tostring(window.id)] = nil
end

---@param event winit_macos_event
function MacEventLoop:dispatch(event)
	local window = self.windows[tostring(event.window)]

	-- An event for a window that is gone is one that arrived while it was being closed, and there
	-- is nothing left for it to be about.
	if not window then
		return
	end

	local callback = self.callback
	local handler = self.handler
	local type = event.type

	if type == Event.windowClose then
		callback({ window = window, name = "windowClose" }, handler)
	elseif type == Event.windowResize then
		window.width = event.width
		window.height = event.height
		callback({ window = window, name = "resize" }, handler)
	elseif type == Event.focusIn then
		callback({ window = window, name = "focusIn" }, handler)
	elseif type == Event.focusOut then
		callback({ window = window, name = "focusOut" }, handler)
	elseif type == Event.mouseMove then
		-- Where the pointer is and how far it went, which are two things a program asks for
		-- separately: the distance is what a mouse turning a view is made of, and it is the only
		-- part of a pointer that survives being held -- see `winit.Event`'s own `mouseMotion`.
		if event.dx ~= 0 or event.dy ~= 0 then
			callback({ name = "mouseMotion", dx = event.dx, dy = event.dy }, handler)
		end

		callback({ window = window, name = "mouseMove", x = event.x, y = event.y }, handler)
	elseif type == Event.mousePress then
		callback({
			window = window,
			name = "mousePress",
			x = event.x,
			y = event.y,
			button = mouseButtons[event.button] or event.button + 1
		}, handler)
	elseif type == Event.mouseRelease then
		callback({
			window = window,
			name = "mouseRelease",
			x = event.x,
			y = event.y,
			button = mouseButtons[event.button] or event.button + 1
		}, handler)
	elseif type == Event.mouseScroll then
		callback({ window = window, name = "mouseScroll", dx = event.dx, dy = event.dy }, handler)
	elseif type == Event.fileDrop then
		local paths = {}
		for path in ffi.string(event.paths):gmatch("[^\n]+") do
			paths[#paths + 1] = path
		end

		callback({ window = window, name = "fileDrop", paths = paths, x = event.x, y = event.y }, handler)
	elseif type == Event.keyPress or type == Event.keyRelease then
		-- A key this does not know the name of is one a program has nothing to say about: the keys
		-- whose names are their own are the ones a binding is written with.
		local key = keyNames[event.keycode]

		if key then
			local pressed = type == Event.keyPress

			callback({
				window = window,
				name = pressed and "keyPress" or "keyRelease",
				key = key,
				modifiers = modifiersOf(event.modifiers),
				text = pressed and textFor(ffi.string(event.text)) or nil,
				repeated = pressed and event.repeated ~= 0 and true or nil
			}, handler)
		end
	end
end

---@param callback winit.EventHandler
function MacEventLoop:run(callback)
	self.isActive = true
	self.currentMode = "poll"
	self.timeout = nil
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

	local event = self.event
	local aboutToWait = { name = "aboutToWait" }

	while self.isActive do
		if self.currentMode == "poll" then
			-- What is already there is taken in one go, which is what a burst of events -- a pointer
			-- being dragged -- is for: the frame that comes of them is the pointer where it is now
			-- rather than one frame per event, each drawn from a state already behind it.
			while shim.winit_macos_next_event(event, 0) ~= 0 do
				self:dispatch(event)
			end
		elseif self.timeout then
			-- A wait with an end to it: what a screen with something to do on its own asks for, and
			-- what the shim is given as how long it may take before answering that nothing came.
			local seconds = self.timeout
			self.timeout = nil

			if shim.winit_macos_next_event(event, seconds) ~= 0 then
				self:dispatch(event)
			end
		else
			-- Nothing asked for: the wait has no end but the next event, which is what a window
			-- nothing is happening to is worth spending.
			shim.winit_macos_next_event(event, -1)
			self:dispatch(event)
		end

		for _, window in pairs(self.windows) do
			if window.shouldRedraw then
				window.shouldRedraw = false
				self.callback({ name = "redraw", window = window }, self.handler)
			end
		end

		self.callback(aboutToWait, self.handler)
	end

	for _, window in pairs(self.windows) do
		self:close(window)
	end
end

--- A clipboard on this platform is the system's own, held as a whole and named by what it holds
--- rather than by who offered it: what a program puts on it is there for every other program, and
--- what it reads is whatever the last one left. There is nothing to keep alive in between, which
--- is why nothing here is asked of the loop it is made from.
---@class winit-macos.Clipboard: winit.Clipboard
local MacClipboard = {}
MacClipboard.__index = MacClipboard

---@param eventLoop winit-macos.EventLoop
---@return winit-macos.Clipboard
function MacClipboard.new(eventLoop)
	return setmetatable({}, MacClipboard)
end

---@param text string
function MacClipboard:setText(text)
	if shim.winit_macos_clipboard_set(text) ~= 0 then
		error("Failed to put text on the clipboard")
	end
end

---@return string?
function MacClipboard:getText()
	-- Asked for its size first and read afterwards, so that a program pasting a page of text is not
	-- handed a page of text cut to fit a guess.
	local length = shim.winit_macos_clipboard_get(nil, 0)

	if length < 0 then
		return nil
	end

	local buffer = ffi.new("char[?]", length + 1)
	shim.winit_macos_clipboard_get(buffer, length + 1)

	return ffi.string(buffer, length)
end

function MacClipboard:clear()
	shim.winit_macos_clipboard_clear()
end

return { Window = MacWindow, EventLoop = MacEventLoop, Clipboard = MacClipboard }
