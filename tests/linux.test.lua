if jit.os ~= "Linux" then
	return
end

local x11 = require("x11api")
local winit = require("winit")
local test = require("lpm-test")

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
