if jit.os ~= "Windows" then
	return
end

local test = require("lpm-test")
local winit = require("winit")
local user32 = require("winapi.user32")
local kernel32 = require("winapi.kernel32")

local EventLoop = winit.EventLoop
local Window = winit.Window

-- Fixture to ensure clean window class state
local function withEventLoop(fn)
	local hInstance = kernel32.getModuleHandle(nil)
	local eventLoop = EventLoop.new()

	local ok, err = pcall(fn, eventLoop)

	-- Cleanup: unregister the window class
	eventLoop:cleanup(hInstance)

	if not ok then
		error(err)
	end
end

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
		test.notEqual(user32.isWindowVisible(window.hwnd), false)

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

test.it("creates window from event loop with default dimensions", function()
	withEventLoop(function(eventLoop)
		local win = Window.fromEventLoop(eventLoop)

		test.notEqual(win, nil)
		test.equal(win.width, 1200)
		test.equal(win.height, 720)
		test.equal(user32.isWindow(win.hwnd), true)

		local rect = user32.Rect()
		local gotRect = user32.getClientRect(win.hwnd, rect)
		test.equal(gotRect, true)

		local clientW = rect.right - rect.left
		local clientH = rect.bottom - rect.top
		test.equal(clientW, 1200)
		test.equal(clientH, 720)

		win:destroy()
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
