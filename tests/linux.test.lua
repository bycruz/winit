if jit.os ~= "Linux" then
	return
end

local x11 = require("x11api")
local winit = require("winit")
local test = require("lde-test")

local EventLoop = winit.EventLoop
local Window = winit.Window

local function setup()
	local eventLoop = EventLoop.new() ---@cast eventLoop winit.x11.EventLoop
	local window = Window.new(eventLoop, 800, 600) ---@cast window winit.x11.Window
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

test.it("should be visible and have correct geometry via xwininfo", function()
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

test.it("should set window title via setTitle", function()
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

test.it("should create a window via Window.fromEventLoop with default dimensions", function()
	local eventLoop = EventLoop.new() ---@cast eventLoop winit.x11.EventLoop
	local window = Window.fromEventLoop(eventLoop) ---@cast window winit.x11.Window

	test.notEqual(window, nil)
	test.equal(window.width, 1200)
	test.equal(window.height, 720)

	local attrs = x11.getWindowAttributes(eventLoop.display, window.id)
	test.notEqual(attrs, nil)
	test.equal(attrs.width, 1200)
	test.equal(attrs.height, 720)

	teardown(eventLoop, window)
end)

test.it("should set and reset cursor without errors", function()
	local eventLoop = EventLoop.new() ---@cast eventLoop winit.x11.EventLoop
	local window = Window.new(eventLoop, 200, 200) ---@cast window winit.x11.Window

	window:setCursor("pointer")
	window:setCursor("hand2")
	window:resetCursor()

	test.equal(window.currentCursor, nil)

	teardown(eventLoop, window)
end)
