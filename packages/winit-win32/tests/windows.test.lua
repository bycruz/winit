local test = require("lde-test")

if jit.os ~= "Windows" then
	-- A window needs a desktop to be put on, and this package has no other way of getting
	-- one: the monorepo's tests run every package on every platform, so this one says what it
	-- is rather than looking like a file that registered nothing at all.
	test.skip("win32 window tests (skipped: not Windows)")
	return
end

local ffi = require("ffi")
local winit = require("winit-win32")
local user32 = require("winapi.user32")
local kernel32 = require("winapi.kernel32")

local EventLoop = winit.EventLoop
local Window = winit.Window
local Clipboard = winit.Clipboard
local FileDialog = winit.FileDialog

-- Fixture to ensure clean window class state
---@param fn fun(eventLoop: winit-win32.EventLoop)
local function withEventLoop(fn)
	local hInstance = kernel32.getModuleHandle(nil)
	local eventLoop = EventLoop.new() ---@cast eventLoop winit-win32.EventLoop

	local ok, err = pcall(fn, eventLoop)

	-- safety: a window still alive keeps its class registered, and every loop made after this
	-- one would fail to register it -- so whatever the test did, its windows are closed here,
	-- including the ones a test that failed part way through never got to close itself
	for _, window in pairs(eventLoop.windows) do
		if user32.isWindow(window.hwnd) then
			window:destroy()
		end
	end

	-- Cleanup: unregister the window class
	eventLoop:cleanup(hInstance)

	if not ok then
		error(err)
	end
end

test.it("offers the system folder dialog", function()
	test.truthy(FileDialog ~= nil)
	test.truthy(type(FileDialog.open) == "function")
end)

test.it("calls a method of a COM object through its vtable", function()
	-- A COM object is a pointer to a pointer to an array of function pointers. Whatever is cast to
	-- reach it has to leave the array typed, or nothing can be read out of it: what this checks is
	-- the cast, with an object of this test's own rather than one of Windows'.
	local com = require("winit-win32.com")

	local answer = ffi.cast("int (*)(int)", function(argument)
		return argument + 1
	end)
	local vtable = ffi.new("void *[4]")
	vtable[3] = ffi.cast("void *", answer)

	local object = ffi.new("void *[1]")
	object[0] = ffi.cast("void *", vtable)

	local call = com.method(ffi.cast("void *", object), 3, "int (*)(int)")
	test.equal(tonumber(call(41)), 42, "the fourth slot of the vtable is the one called")
end)

test.it("leaves the COM entry points to the rest of the process", function()
	-- What an audio library declares after winit is loaded: its own GUID struct, and
	-- CoCreateInstance taking it. winit loaded first must not have claimed that name with a
	-- struct of its own, or the call below is refused before it reaches COM.
	pcall(ffi.cdef, [[
		typedef struct { uint32_t Data1; uint16_t Data2; uint16_t Data3; uint8_t Data4[8]; } TEST_GUID;
		int32_t CoCreateInstance(const TEST_GUID *clsid, void *outer, uint32_t context,
			const TEST_GUID *iid, void **out);
	]])
	local ole32 = ffi.load("ole32")
	local guid = ffi.new("TEST_GUID")
	local out = ffi.new("void *[1]")

	local ok, err = pcall(function()
		return ole32.CoCreateInstance(guid, nil, 1, guid, out)
	end)
	test.truthy(ok, tostring(err))
end)

test.it("creates an event loop", function()
	withEventLoop(function(eventLoop)
		test.notEqual(eventLoop, nil)
	end)
end)

test.it("creates a window with correct dimensions", function()
	withEventLoop(function(eventLoop)
		local window = Window.new(eventLoop, 800, 600)
		eventLoop:register(window)

		test.notEqual(window, nil)
		test.equal(window.width, 800)
		test.equal(window.height, 600)
		test.notEqual(window.hwnd, nil)

		window:destroy()
	end)
end)

test.it("creates a valid Win32 window handle", function()
	withEventLoop(function(eventLoop)
		local window = Window.new(eventLoop, 800, 600)
		eventLoop:register(window)

		test.notEqual(user32.isWindow(window.hwnd), false)

		-- Whether this session can show a window at all is its own business -- one that is only
		-- a connection, which is what a machine driven over ssh has, reports every window it
		-- makes as not visible -- so what is asked here is what the program asked for: a window
		-- created to be seen, which is the style it carries.
		local style = user32.getWindowLongPtr(window.hwnd, user32.GWLP.STYLE)
		test.equal(bit.band(style, user32.WS.VISIBLE) ~= 0, true)

		window:destroy()
	end)
end)

test.it("has correct client area dimensions", function()
	withEventLoop(function(eventLoop)
		local window = Window.new(eventLoop, 800, 600)
		eventLoop:register(window)

		local rect = user32.Rect()
		local gotRect = user32.getClientRect(window.hwnd, rect)

		test.equal(gotRect, true)

		local clientW = rect.right - rect.left
		local clientH = rect.bottom - rect.top
		test.equal(clientW, 800)
		test.equal(clientH, 600)

		window:destroy()
	end)
end)

test.it("sets and retrieves window title", function()
	withEventLoop(function(eventLoop)
		local window = Window.new(eventLoop, 800, 600)
		eventLoop:register(window)

		window:setTitle("winit test window")

		local title = user32.getWindowText(window.hwnd)

		test.notEqual(title, nil)
		test.equal(title, "winit test window")

		window:destroy()
	end)
end)

test.it("runs event loop and receives aboutToWait event", function()
	withEventLoop(function(eventLoop)
		local window = Window.new(eventLoop, 800, 600)
		eventLoop:register(window)

		local events = {}
		local eventCount = 0

		eventLoop:run(function(event, handler)
			---@cast event winit.Event
			---@cast handler winit.EventManager
			handler:setMode("poll")
			eventCount = eventCount + 1
			events[event.name] = true

			if eventCount > 20 or events["aboutToWait"] then
				handler:exit()
			end
		end)

		test.equal(events["aboutToWait"], true)
	end)
end)

test.it("invalidates window handle after destroy", function()
	withEventLoop(function(eventLoop)
		local window = Window.new(eventLoop, 200, 200)
		eventLoop:register(window)

		local hwnd = window.hwnd
		window:destroy()

		test.equal(user32.isWindow(hwnd), false)
	end)
end)

test.it("sets cursor without error", function()
	withEventLoop(function(eventLoop)
		local window = Window.new(eventLoop, 200, 200)
		eventLoop:register(window)

		window:setCursor("pointer")
		window:setCursor("hand2")
		window:resetCursor()

		window:destroy()
	end)
end)

test.it("handles multiple event loops in sequence", function()
	-- First event loop
	withEventLoop(function(eventLoop1)
		local win1 = Window.new(eventLoop1, 400, 300)
		eventLoop1:register(win1)
		test.notEqual(win1, nil)
		win1:destroy()
	end)

	-- Second event loop (tests that class unregistration worked)
	withEventLoop(function(eventLoop2)
		local win2 = Window.new(eventLoop2, 500, 400)
		eventLoop2:register(win2)
		test.notEqual(win2, nil)
		win2:destroy()
	end)
end)

test.it("offers text to the clipboard and reads it back", function()
	local clipboard = Clipboard.new(nil)

	clipboard:setText("offered by winit")
	test.equal(clipboard:getText(), "offered by winit")

	-- Text that is not ASCII is text a program copies and pastes as readily as any other, and
	-- the clipboard is where the two encodings a Lua string and Windows use meet.
	clipboard:setText("héllo — 世界")
	test.equal(clipboard:getText(), "héllo — 世界")

	-- Long enough that the block handed to the clipboard is not one small allocation by
	-- accident, and that a read of it is a read of the whole thing.
	local long = string.rep("winit ", 5000)
	clipboard:setText(long)
	test.equal(clipboard:getText(), long)

	-- An empty string is on the clipboard and is not the same as nothing being there.
	clipboard:setText("")
	test.equal(clipboard:getText(), "")

	clipboard:clear()
	test.equal(clipboard:getText(), nil)
end)

--- The block of memory the shell hands a window for a drop: a DROPFILES header, then the file
--- names one after another, each ending in a null, and a second null after the last of them.
---@param paths string[]
---@param x number
---@param y number
---@return winapi.shell32.ffi.HDROP
local function makeDrop(paths, x, y)
	---@type ffi.ptr<ffi.wchar_t>[]
	local wides = {}
	local units = 1

	for i, path in ipairs(paths) do
		local wide = ffi.cast("wchar_t*", assert(kernel32.utf8ToWide(path)))
		wides[i] = wide

		local characters = 0
		while wide[characters] ~= 0 do
			characters = characters + 1
		end

		units = units + characters + 1
	end

	local headerSize = ffi.sizeof("DROPFILES")
	local handle = kernel32.globalAlloc(kernel32.GMEM.MOVEABLE, headerSize + units * 2)
	test.notEqual(handle, nil, "the drop could not be built")
	---@cast handle -nil

	local block = kernel32.globalLock(handle)
	---@cast block -nil

	---@type { pFiles: number, pt: { x: number, y: number }, fNC: number, fWide: number }
	local header = ffi.cast("DROPFILES *", block)
	header.pFiles = headerSize
	header.pt.x = x
	header.pt.y = y
	header.fNC = 0

	-- Names in UTF-16, which is what a dropped file's path is on Windows and what DragQueryFileW
	-- reads; the older name-only form is what this says not to expect.
	header.fWide = 1

	local names = ffi.cast("char *", block) + headerSize --[[@as ffi.ptr<ffi.char>]]
	local at = 0

	for _, wide in ipairs(wides) do
		local characters = 0
		while wide[characters] ~= 0 do
			ffi.cast("WCHAR *", names)[at] = wide[characters]
			characters = characters + 1
			at = at + 1
		end

		ffi.cast("WCHAR *", names)[at] = 0
		at = at + 1
	end

	ffi.cast("WCHAR *", names)[at] = 0
	kernel32.globalUnlock(handle)

	return handle
end

test.it("reports the files a drop carried, and where it was let go of", function()
	withEventLoop(function(eventLoop)
		local window = Window.new(eventLoop, 400, 300)
		eventLoop:register(window)

		-- The shell is what hands a window its drops, and a window that never registered for
		-- them is one it does not hand anything to: what is posted here is the same message
		-- carrying the same block, which is as close as a test comes to a drag.
		local drop = makeDrop({ "C:\\Users\\Viola\\one.txt", "C:\\Users\\Viola\\two words.txt" }, 12, 34)
		test.equal(user32.postMessage(window.hwnd, user32.WM.DROPFILES, ffi.cast("uintptr_t", drop), 0), true)

		---@type winit.Event?
		local dropped = nil
		local frames = 0

		eventLoop:run(function(event, handler)
			---@cast event winit.Event
			---@cast handler winit.EventManager
			handler:setMode("poll")

			if event.name == "fileDrop" then
				dropped = event
			end

			frames = frames + 1
			if dropped or frames > 200 then
				handler:exit()
			end
		end)

		test.notEqual(dropped, nil, "the drop never reached the program")
		---@cast dropped -nil
		test.equal(dropped.window, window)
		test.deepEqual(dropped.paths, { "C:\\Users\\Viola\\one.txt", "C:\\Users\\Viola\\two words.txt" })

		-- Where the drop was let go of is where the pointer was, in the window's own corner.
		test.equal(dropped.x, 12)
		test.equal(dropped.y, 34)
	end)
end)

test.it("reports a wheel as scroll events in notches, down the page positive", function()
	withEventLoop(function(eventLoop)
		local window = Window.new(eventLoop, 400, 300)
		eventLoop:register(window)

		-- The delta is the signed high word of wParam, in multiples of 120: a notch away from the
		-- user, a notch towards them, half a notch of a finer wheel, and a tilt to the right. Windows
		-- builds wParam from 32 bits, so the word above them is zero rather than the delta's sign.
		local function wheel(message, delta)
			local wParam = ffi.cast("uintptr_t", ffi.cast("uint32_t", bit.lshift(bit.band(delta, 0xFFFF), 16)))
			test.equal(user32.postMessage(window.hwnd, message, wParam, 0), true)
		end
		wheel(user32.WM.MOUSEWHEEL, 120)
		wheel(user32.WM.MOUSEWHEEL, -120)
		wheel(user32.WM.MOUSEWHEEL, -60)
		wheel(user32.WM.MOUSEHWHEEL, 120)

		---@type winit.Event[]
		local scrolls = {}
		local frames = 0

		eventLoop:run(function(event, handler)
			---@cast event winit.Event
			---@cast handler winit.EventManager
			handler:setMode("poll")

			if event.name == "mouseScroll" then
				scrolls[#scrolls + 1] = event
			end

			frames = frames + 1
			if #scrolls == 4 or frames > 200 then
				handler:exit()
			end
		end)

		test.equal(#scrolls, 4, "every wheel message reaches the program")
		test.equal(scrolls[1].window, window)
		test.equal(scrolls[1].dy, -1, "a notch away from the user goes up the page")
		test.equal(scrolls[2].dy, 1, "a notch towards the user goes down the page")
		test.equal(scrolls[3].dy, 0.5, "a finer wheel reports a fraction of a notch")
		test.equal(scrolls[4].dx, 1, "a tilt to the right goes right")
		test.equal(scrolls[4].dy, 0)
	end)
end)

test.it("reports the keys of the keyboard, and what they type", function()
	withEventLoop(function(eventLoop)
		local window = Window.new(eventLoop, 400, 300)
		eventLoop:register(window)

		-- A press is a virtual key code in the low byte of wParam and its scan code in lParam, which
		-- is what the layout is asked with: the same message the keyboard sends.
		local function key(message, virtual, scan, flags)
			local wParam = ffi.cast("uintptr_t", virtual)
			local lParam = ffi.cast("intptr_t", bit.bor(bit.lshift(scan, 16), flags or 0))
			test.equal(user32.postMessage(window.hwnd, message, wParam, lParam), true)
		end

		local A, LEFT, BACKSPACE, SHIFT = 0x41, 0x25, 0x08, 0x10
		key(user32.WM.KEYDOWN, A, 0x1E)
		key(user32.WM.KEYUP, A, 0x1E)
		key(user32.WM.KEYDOWN, LEFT, 0x4B)
		key(user32.WM.KEYUP, LEFT, 0x4B)
		key(user32.WM.KEYDOWN, BACKSPACE, 0x0E)
		key(user32.WM.KEYUP, BACKSPACE, 0x0E)
		-- A press the keyboard says is a repeat of one it is holding: the thirty-first bit of lParam.
		key(user32.WM.KEYDOWN, A, 0x1E, 0x40000000)

		---@type winit.Event[]
		local keys = {}
		local frames = 0

		eventLoop:run(function(event, handler)
			---@cast event winit.Event
			---@cast handler winit.EventManager
			handler:setMode("poll")

			if event.name == "keyPress" or event.name == "keyRelease" then
				keys[#keys + 1] = event
			end

			frames = frames + 1
			if #keys == 7 or frames > 200 then
				handler:exit()
			end
		end)

		test.equal(#keys, 7, "every key message reaches the program")

		test.equal(keys[1].name, "keyPress")
		test.equal(keys[1].key, "a", "a letter is named by the letter, not by what the shift makes of it")
		test.equal(keys[1].text, "a", "and is told with what it typed")
		test.equal(keys[1].window, window)
		test.equal(keys[1].repeated, nil, "a press of its own is not a repeat")

		test.equal(keys[2].name, "keyRelease")
		test.equal(keys[2].key, "a")

		test.equal(keys[3].key, "left", "a key that types nothing is named for itself")
		test.equal(keys[3].text, nil, "and types nothing")

		test.equal(keys[5].key, "backspace")

		test.equal(keys[7].key, "a")
		test.equal(keys[7].repeated, true, "a press the keyboard says is a repeat is marked as one")
	end)
end)

--- Whether the program the clipboard tests use as a second one is here. PowerShell reads and
--- writes the clipboard through the same door every other program does, which is what makes
--- the exchange below a real one rather than this process talking to itself. What is asked of
--- it is that it runs and says something: where it is missing, the shell writes the bad
--- command to the stream sent nowhere and there is nothing to read.
local function hasPowerShell()
	local pipe = io.popen("powershell -NoProfile -Command \"Write-Output winit\" 2>nul")
	if not pipe then
		return false
	end

	local output = pipe:read("*a") or ""
	pipe:close()

	return output:find("winit", 1, true) ~= nil
end

local external = test.skipIf(not hasPowerShell())

external("offers text a program of its own can read", function()
	local clipboard = Clipboard.new(nil)
	local text = "offered to another program"
	clipboard:setText(text)

	-- What the system hands the clipboard is the system's from then on, so another program
	-- reads it out without this one being alive to answer for it.
	local pipe = io.popen("powershell -NoProfile -Command \"Get-Clipboard\"")
	test.notEqual(pipe, nil) ---@cast pipe -nil

	local served = pipe:read("*a")
	pipe:close()

	-- PowerShell writes what it read as a line, with the line ending a line gets.
	test.equal((served:gsub("%s+$", "")), text)

	clipboard:clear()
end)

external("reads text a program of its own is offering", function()
	local clipboard = Clipboard.new(nil)
	local text = "text another program owns"

	test.equal(os.execute("powershell -NoProfile -Command \"Set-Clipboard -Value '"
		.. text .. "'\""), 0)

	-- The text is another program's, which is the case nothing in this process can stand in
	-- for: what is read is a block the system kept for somebody else.
	test.equal(clipboard:getText(), text)

	clipboard:clear()
end)
