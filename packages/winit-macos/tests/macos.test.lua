local test = require("lde-test")

if jit.os ~= "OSX" then
	-- A window on this platform is a window server's, and there is one only where macOS is: the
	-- monorepo's tests run every package on every platform, so saying so is what keeps this file
	-- from looking like one that registered nothing at all.
	test.skip("macos window tests (skipped: not macOS)")
	return
end

local winit = require("winit-macos")

local EventLoop = winit.EventLoop
local Window = winit.Window

-- A window belongs to the window server, and a machine nobody is logged into the screen of -- a
-- runner in a continuous integration suite, or one reached over ssh while it sits at the login
-- window -- has none to put one on. What is asked here is the question the rest of the file rests
-- on, so it is asked once, and a machine that answers no is one these tests skip rather than fail.
local hasDisplay = pcall(EventLoop.new)
if not hasDisplay then
	test.skip("macos window tests (skipped: no display)")
	return
end

local function setup(width, height)
	local eventLoop = EventLoop.new() ---@cast eventLoop winit-macos.EventLoop
	local window = Window.new(eventLoop, width or 800, height or 600) ---@cast window winit-macos.Window
	eventLoop:register(window)
	return eventLoop, window
end

local function teardown(eventLoop, window)
	eventLoop:close(window)
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

test.it("should look a window up in the loop it was registered with", function()
	local eventLoop, window = setup(320, 240)

	test.equal(eventLoop.windows[tostring(window.id)], window)

	eventLoop:close(window)
	test.equal(eventLoop.windows[tostring(window.id)], nil)
end)

test.it("should hand a program the view a window draws in", function()
	local eventLoop, window = setup()

	-- A renderer is given what it makes its context out of, and what that is on this platform is
	-- the view the window is filled by: a pointer is all a program does with it, so what is tested
	-- is that there is one at all.
	test.notEqual(window:nativeView(), nil)

	teardown(eventLoop, window)
end)

test.it("should set a window's title and take the cursors it is offered", function()
	local eventLoop, window = setup()

	window:setTitle("a window of a program's own")
	window:setCursor("hand2")
	window:setCursor("pointer")
	window:resetCursor()

	window:setCursorGrab("locked")
	test.equal(window.cursorGrab, "locked")

	window:setCursorGrab("none")
	test.equal(window.cursorGrab, "none")

	teardown(eventLoop, window)
end)

test.it("should offer text to the clipboard and read it back", function()
	local eventLoop, window = setup()
	local clipboard = winit.Clipboard.new(eventLoop)

	clipboard:setText("offered by winit")
	test.equal(clipboard:getText(), "offered by winit")

	-- What a program puts on the clipboard is the system's from then on, which is what makes a
	-- paste in another program work: it is read back out of the same place it was put.
	clipboard:setText("héllo — 世界")
	test.equal(clipboard:getText(), "héllo — 世界")

	clipboard:clear()
	test.equal(clipboard:getText(), nil)

	teardown(eventLoop, window)
end)

test.it("should run the loop, making a window and waiting on what is next", function()
	local eventLoop, window = setup(320, 240)

	local seen = {}
	local waited = 0

	-- What is asked of the machine here is a screen that is there: the loop says a window was made
	-- and then, having nothing else to do, that it is about to wait -- and a program that has heard
	-- that a few times has seen everything a window nothing has happened to can offer.
	eventLoop:run(function(event, handler)
		seen[event.name] = (seen[event.name] or 0) + 1

		if event.name == "aboutToWait" then
			waited = waited + 1

			if waited >= 3 then
				handler:exit()
			end
		end
	end)

	test.equal(seen.create, 1)
	test.equal(seen.aboutToWait, 3)
	test.equal(eventLoop.isActive, false)
end)

test.it("should wake a waiting loop at the deadline it was given", function()
	local eventLoop, window = setup(320, 240)

	local started = os.clock()
	local wakes = 0

	-- Nothing is happening to this window and nothing is going to, so a loop that took what was
	-- there would come back on its own and one that waited out an event would never come back at
	-- all: what a deadline is for is the screen with something of its own to do -- a caret that
	-- blinks -- and what it is worth is a loop that comes back on the time it was asked for.
	-- Whether it waited is counted in the time the program spent rather than in the time that
	-- passed, and a loop that came back early is one that spent its share of it.
	eventLoop:run(function(event, handler)
		if event.name ~= "aboutToWait" then
			return
		end

		wakes = wakes + 1
		handler:setMode("wait")
		handler:setTimeout(0.05)

		if wakes >= 3 then
			handler:exit()
		end
	end)

	test.equal(wakes, 3)
	test.truthy(os.clock() - started < 0.1)
end)
