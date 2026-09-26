local test = require("lde-test")
local winit = require("winit")

-- What is tested here is winit's own half -- which backend it hands a program, and what a
-- window and a clipboard made from it do -- and a machine with nowhere to put a window has
-- nothing to test it on: the monorepo's tests run every package on every platform, so this
-- says so rather than looking like a file that registered nothing at all.
local made, eventLoop = pcall(winit.EventLoop.new)
if not made then
	test.skip("winit tests (skipped: no display)")
	return
end

---@cast eventLoop winit.EventLoop

test.it("should hand a program the backend of the platform it runs on", function()
	-- Both backends' packages are here in the monorepo, and a program installs one of them:
	-- what it is handed is that one's classes, not a wrapper this package keeps in front of
	-- them -- a window of a program is the backend's own, down to the fields on it.
	local backend = require(({
		Windows = "winit-win32",
		Linux = "winit-x11",
		OSX = "winit-macos"
	})[jit.os])

	test.equal(winit.Window, backend.Window)
	test.equal(winit.EventLoop, backend.EventLoop)
	test.equal(winit.Clipboard, backend.Clipboard)
end)

test.it("should make a window from a loop, at the size a program gets by default", function()
	local window = winit.Window.fromEventLoop(eventLoop)

	test.notEqual(window, nil)
	test.equal(window.width, 1200)
	test.equal(window.height, 720)

	-- The loop is where a window is looked up by the id the platform gives it, which is what
	-- the events it makes are routed with.
	test.equal(eventLoop.windows[tostring(window.id)], window)

	eventLoop:close(window)
	test.equal(eventLoop.windows[tostring(window.id)], nil)
end)

test.it("should offer text to the clipboard and read it back", function()
	local clipboard = winit.Clipboard.new(eventLoop)

	clipboard:setText("offered by winit")
	test.equal(clipboard:getText(), "offered by winit")

	-- Text a program writes is text it reads back as the same bytes, whatever they are.
	clipboard:setText("héllo — 世界")
	test.equal(clipboard:getText(), "héllo — 世界")

	clipboard:clear()
	test.equal(clipboard:getText(), nil)
end)
