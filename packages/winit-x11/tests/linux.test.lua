local test = require("lde-test")

if jit.os ~= "Linux" then
	-- An X display is not something this package has another way of getting, and the
	-- monorepo's tests run every package on every platform: saying so is what keeps this
	-- file from looking like one that registered nothing at all.
	test.skip("x11 window tests (skipped: not Linux)")
	return
end

local x11 = require("x11api")
local winit = require("winit-x11")

local EventLoop = winit.EventLoop
local Window = winit.Window

local function setup()
	local eventLoop = EventLoop.new() ---@cast eventLoop winit-x11.EventLoop
	local window = Window.new(eventLoop, 800, 600) ---@cast window winit-x11.Window
	eventLoop:register(window)
	x11.flush(eventLoop.display)
	return eventLoop, window
end

local function teardown(eventLoop, window)
	window:destroy()
	x11.closeDisplay(eventLoop.display)
end

test.it("should create an event loop and window with correct dimensions", function()
	local eventLoop, window = setup()

	test.notEqual(eventLoop, nil)
	test.notEqual(window, nil)
	test.equal(window.width, 800)
	test.equal(window.height, 600)
	test.notEqual(window.id, nil)
	test.notEqual(window.id, 0)

	teardown(eventLoop, window)
end)

test.it("should report correct attributes via X11 API", function()
	local eventLoop, window = setup()
	os.execute("sleep 0.1")

	local attrs = x11.getWindowAttributes(eventLoop.display, window.id)
	test.notEqual(attrs, nil)
	test.equal(attrs.width, 800)
	test.equal(attrs.height, 600)

	teardown(eventLoop, window)
end)

--- Whether a tool the tests ask about a window is on this machine. What these check is that
--- the display agrees with a program outside this one about what the window looks like, and
--- that is a question only such a program can answer.
---@param name string
---@return boolean
local function hasTool(name)
	local pipe = io.popen("command -v " .. name .. " 2>/dev/null")
	if not pipe then
		return false
	end

	local path = pipe:read("*a")
	pipe:close()

	return path ~= ""
end

test.skipIf(not hasTool("xwininfo"))("should be visible and have correct geometry via xwininfo", function()
	local eventLoop, window = setup()
	os.execute("sleep 0.1")

	local windowIdHex = string.format("0x%x", tonumber(window.id))
	local tmpFile = "/tmp/winit_test_xwininfo_" .. os.time() .. ".txt"
	os.execute("xwininfo -id " .. windowIdHex .. " > " .. tmpFile .. " 2>&1")

	local f = io.open(tmpFile, "r")
	test.notEqual(f, nil)
	local output = f:read("*a")
	f:close()
	os.remove(tmpFile)

	test.notEqual(output:match("Width:%s*(%d+)"), nil)
	test.equal(tonumber(output:match("Width:%s*(%d+)")), 800)
	test.equal(tonumber(output:match("Height:%s*(%d+)")), 600)

	teardown(eventLoop, window)
end)

test.skipIf(not hasTool("xprop"))("should set window title via setTitle", function()
	local eventLoop, window = setup()

	window:setTitle("winit test window")
	x11.flush(eventLoop.display)
	os.execute("sleep 0.05")

	local windowIdHex = string.format("0x%x", tonumber(window.id))
	local tmpFile = "/tmp/winit_test_xprop_" .. os.time() .. ".txt"
	os.execute("xprop -id " .. windowIdHex .. " _NET_WM_NAME > " .. tmpFile .. " 2>&1")

	local f = io.open(tmpFile, "r")
	test.notEqual(f, nil)
	local output = f:read("*a")
	f:close()
	os.remove(tmpFile)

	test.notEqual(output:find("winit test window"), nil)

	teardown(eventLoop, window)
end)

test.it("should emit an aboutToWait event when running the loop", function()
	local eventLoop, window = setup()

	local gotAboutToWait = false
	local count = 0

	eventLoop:run(function(event, handler)
		handler:setMode("poll")
		count = count + 1
		if event.name == "aboutToWait" then
			gotAboutToWait = true
		end
		if count > 20 or gotAboutToWait then
			handler:exit()
		end
	end)

	test.equal(gotAboutToWait, true)

	teardown(eventLoop, window)
end)

--- The keycode a keysym sits on, since X answers that question the other way round.
---@param display x11.ffi.Display
---@param keysym number
---@return number
local function keycodeOf(display, keysym)
	for keycode = 8, 255 do
		if tonumber(x11.keycodeToKeysym(display, keycode, 0)) == keysym then
			return keycode
		end
	end
	error("no keycode for keysym " .. keysym)
end

test.it("should name a key after the key and not after the text a modifier makes it type", function()
	local eventLoop, window = setup()
	local display = eventLoop.display

	-- the key W, pressed while control is held, which X types as a control character
	local keycode = keycodeOf(display, 0x77)

	local event = x11.Event()
	event.type = x11.EventType.KeyPress
	event.xkey.window = window.id
	event.xkey.keycode = keycode
	event.xkey.state = 4 -- ControlMask

	x11.sendEvent(display, window.id, x11.False, x11.EventMaskBits.KeyPress, event)
	x11.flush(display)

	local keys = {}
	local frames = 0
	eventLoop:run(function(seen, handler)
		handler:setMode("poll")
		frames = frames + 1
		if seen.name == "keyPress" then
			keys[#keys + 1] = seen.key
			handler:exit()
		end
		if frames > 60 then
			handler:exit()
		end
	end)

	test.equal(#keys, 1)
	test.equal(keys[1], "w")

	teardown(eventLoop, window)
end)

--- A key event, as the keyboard would make it: sent to the window, which is where the loop reads
--- them from.
---@param display x11.ffi.Display
---@param window winit-x11.Window
---@param name string # "KeyPress" or "KeyRelease"
---@param keycode number
---@param state number # The modifiers held, as X masks them
---@param at number? # And the time the server would stamp it with
local function sendKey(display, window, name, keycode, state, at)
	local event = x11.Event()

	event.type = name == "KeyPress" and x11.EventType.KeyPress or x11.EventType.KeyRelease
	event.xkey.window = window.id
	event.xkey.keycode = keycode
	event.xkey.state = state
	event.xkey.time = at or 0

	x11.sendEvent(display, window.id, x11.False,
		name == "KeyPress" and x11.EventMaskBits.KeyPress or x11.EventMaskBits.KeyRelease, event)
	x11.flush(display)
end

--- Runs the loop until it has seen `count` keys, and hands back what it saw of them. The events are
--- sent through the server, so it waits for them to be there: the loop is run in poll mode, which
--- does not wait for anything by itself.
---@param eventLoop winit-x11.EventLoop
---@param count number
---@return { name: string, key: string, text: string?, repeated: boolean? }[]
local function seenKeys(eventLoop, count)
	local display = eventLoop.display
	local seen = {}
	local frames = 0

	for _ = 1, 100000 do
		if x11.pending(display) >= count then break end
	end

	eventLoop:run(function(event, handler)
		handler:setMode("poll")
		frames = frames + 1

		if event.name == "keyPress" or event.name == "keyRelease" then
			seen[#seen + 1] = {
				name = event.name,
				key = event.key,
				text = event.text,
				repeated = event.repeated,
			}
		end

		if #seen >= count or frames > 60 then
			handler:exit()
		end
	end)

	return seen
end

test.it("should name a shifted key after the key, and say what it types as the text", function()
	local eventLoop, window = setup()
	local display = eventLoop.display

	-- the key 1 with shift held, which types "!" -- the key is the key, and what it types is the text
	local keycode = keycodeOf(display, 0x31)

	sendKey(display, window, "KeyPress", keycode, 1) -- ShiftMask
	sendKey(display, window, "KeyRelease", keycode, 1)

	local seen = seenKeys(eventLoop, 2)

	test.equal(#seen, 2, "the press and the release are both reported")
	test.equal(seen[1].key, "1", "the press is named after the key")
	test.equal(seen[1].text, "!", "and what it types is the text")
	test.equal(seen[2].key, "1", "the release is named after the same key as the press")

	teardown(eventLoop, window)
end)

test.it("should say which presses and releases are the keyboard's own repeat", function()
	local eventLoop, window = setup()
	local display = eventLoop.display
	local keycode = keycodeOf(display, 0x62) -- the key b

	-- what a keyboard repeating a key it is holding sends: a release and a press of it together,
	-- with the same keycode and the same time. Sent before the loop runs, so that the press is in
	-- the queue when the release is read -- which is what it is read against.
	sendKey(display, window, "KeyPress", keycode, 0, 100)
	sendKey(display, window, "KeyRelease", keycode, 0, 100)
	sendKey(display, window, "KeyPress", keycode, 0, 100)

	local seen = seenKeys(eventLoop, 3)

	test.equal(#seen, 3, "all three are reported")
	test.equal(seen[1].name, "keyPress")
	test.equal(seen[1].repeated, nil, "the first press is a hand making it")
	test.equal(seen[2].name, "keyRelease")
	test.equal(seen[2].repeated, true, "the release a repeat comes with says so")
	test.equal(seen[3].name, "keyPress")
	test.equal(seen[3].repeated, true, "and the press of that repeat says so")

	-- A release of its own, with nothing behind it: the key is up, and the next press is a hand's.
	sendKey(display, window, "KeyRelease", keycode, 0, 200)
	sendKey(display, window, "KeyPress", keycode, 0, 300)

	local alone = seenKeys(eventLoop, 2)

	test.equal(alone[1].name, "keyRelease")
	test.equal(alone[1].repeated, nil, "a release on its own is a key coming up")
	test.equal(alone[2].repeated, nil, "and the press after it is a hand making it")

	teardown(eventLoop, window)
end)

test.it("should name a release after the press it belongs to, whatever the key is", function()
	local eventLoop, window = setup()
	local display = eventLoop.display

	-- a keypad key: its keycode names nothing on its own and types nothing when it comes up, so what
	-- a release of it is called is what its press was called. Skipped where the keyboard has no
	-- keypad to speak of.
	local ok, keycode = pcall(keycodeOf, display, 0xffb1) -- KP_1

	if not ok then
		teardown(eventLoop, window)
		return
	end

	sendKey(display, window, "KeyPress", keycode, 0)
	sendKey(display, window, "KeyRelease", keycode, 0)

	local seen = seenKeys(eventLoop, 2)

	test.equal(#seen, 2, "the press and the release are both reported")
	test.equal(seen[2].key, seen[1].key, "and the release is named what the press was named")
	test.equal(seen[2].name, "keyRelease")

	teardown(eventLoop, window)
end)

test.it("should leave the pointer where a menu put it rather than dragging it to the middle", function()
	local eventLoop, window = setup()
	local display = eventLoop.display

	-- playing grabs the pointer and hides it, and a menu lets go of it again
	window:setCursorGrab("locked")
	window:setCursorGrab("none")

	-- where a player moves the mouse to while a menu is open
	x11.warpPointer(display, 0, window.id, 0, 0, 0, 0, 40, 40)
	x11.flush(display)

	-- safety: a menu asks for the mode it is already in every frame, and asking again is
	-- not a reason to move the pointer back to the middle of the window
	window:setCursorGrab("none")
	x11.flush(display)

	local x, y = x11.queryPointer(display, window.id)
	test.equal(x, 40)
	test.equal(y, 40)

	teardown(eventLoop, window)
end)

test.it("should set and reset cursor without errors", function()
	local eventLoop = EventLoop.new() ---@cast eventLoop winit-x11.EventLoop
	local window = Window.new(eventLoop, 200, 200) ---@cast window winit-x11.Window

	window:setCursor("pointer")
	window:setCursor("hand2")
	window:resetCursor()

	test.equal(window.currentCursor, nil)

	teardown(eventLoop, window)
end)
