local test = require("lde-test")

if jit.os ~= "Linux" then
	-- A clipboard is the display's, and this package has no other way of getting one: the
	-- monorepo's tests run every package on every platform, so this one says what it is
	-- rather than looking like a file that registered nothing at all.
	test.skip("x11 clipboard tests (skipped: not Linux)")
	return
end

local x11 = require("x11api")
local winit = require("winit-x11")
local wait = require("winit-x11.wait")

--- Whether the clipboard tool the tests use as a second program is on this machine. It is
--- what makes the half of the protocol that needs somebody else's program testable at all.
---@return boolean
local function hasXsel()
	local pipe = io.popen("command -v xsel 2>/dev/null")
	if not pipe then
		return false
	end

	local path = pipe:read("*a")
	pipe:close()

	return path ~= ""
end

local external = test.skipIf(not hasXsel())

--- A loop with a clipboard on it, and nothing else: what a clipboard needs is a display and
--- the loop that answers for it, not a window a program put on screen.
---@return winit-x11.EventLoop, winit-x11.Clipboard
local function setup()
	local eventLoop = winit.EventLoop.new()
	return eventLoop, winit.Clipboard.new(eventLoop)
end

test.it("should hand back the text it was told to offer", function()
	local _, clipboard = setup()

	clipboard:setText("a line of text")
	test.equal(clipboard:getText(), "a line of text")

	-- Text that is not ASCII is text a program copies and pastes as readily as any other,
	-- and it is the case where bytes and characters stop being the same thing.
	clipboard:setText("héllo — 世界")
	test.equal(clipboard:getText(), "héllo — 世界")

	-- An empty clipboard and a clipboard holding an empty string are two different things,
	-- and a program pasting needs to tell them apart.
	clipboard:setText("")
	test.equal(clipboard:getText(), "")

	clipboard:clear()
	test.equal(clipboard:getText(), nil)
end)

test.it("should answer a program that asks it for the text", function()
	local eventLoop, clipboard = setup()

	-- A second connection is a second program as far as the server is concerned, which is
	-- what makes the exchange below a real one rather than this process talking to itself.
	local display = x11.openDisplay(nil)
	test.notEqual(display, nil) ---@cast display -nil

	local root = x11.defaultRootWindow(display)
	local requestor = x11.createSimpleWindow(display, root, 0, 0, 10, 10, 0, 0, 0)

	local selection = x11.internAtom(display, "CLIPBOARD", 0)
	local target = x11.internAtom(display, "UTF8_STRING", 0)
	local property = x11.internAtom(display, "WINIT_TEST_CLIPBOARD_ANSWER", 0)

	local text = "handed to another program"
	clipboard:setText(text)

	-- The ownership has to be the server's before the other program asks, and a sync is what
	-- waits for it to be.
	x11.sync(eventLoop.display, x11.False)

	x11.convertSelection(display, selection, target, property, requestor, x11.CurrentTime)
	x11.flush(display)

	local read = nil
	local frames = 0

	eventLoop:run(function(_, handler)
		handler:setMode("poll")

		-- The other program is this process on another connection, so its answer is read
		-- here: what the loop is for is answering the request that came out of the ask.
		while x11.pending(display) > 0 do
			local seen = x11.Event()
			x11.nextEvent(display, seen)

			if seen.type == x11.EventType.SelectionNotify
				and seen.xselection.requestor == requestor
				and seen.xselection.target == target then
				read = x11.getProperty(display, requestor, property, true)
			end
		end

		frames = frames + 1
		if read or frames > 200 then
			handler:exit()
		end
	end)

	test.equal(read, text)

	x11.destroyWindow(display, requestor)
	x11.closeDisplay(display)
end)

test.it("should say nothing when no program is offering anything", function()
	local eventLoop, clipboard = setup()

	local display = x11.openDisplay(nil)
	test.notEqual(display, nil) ---@cast display -nil

	-- Whatever else on this display may be holding the clipboard, this is what nothing on it
	-- looks like: an owner of None is an empty clipboard, and asking for it is answered with
	-- nothing rather than with silence.
	local selection = x11.internAtom(display, "CLIPBOARD", 0)
	x11.setSelectionOwner(display, selection, 0, x11.CurrentTime)
	x11.sync(display, x11.False)

	local started = wait.monotonic()
	test.equal(clipboard:getText(), nil)

	-- And it is answered rather than waited out: an owner of None has nothing to answer with.
	test.less(wait.monotonic() - started, 0.5)

	x11.closeDisplay(display)
end)

test.it("should give up on an owner that never answers", function()
	local _, clipboard = setup()

	local display = x11.openDisplay(nil)
	test.notEqual(display, nil) ---@cast display -nil

	-- A window that owns the selection and never answers a request for it is what a hung
	-- program looks like from the outside, and what a paste must not wait on for good.
	local root = x11.defaultRootWindow(display)
	local owner = x11.createSimpleWindow(display, root, 0, 0, 10, 10, 0, 0, 0)

	local selection = x11.internAtom(display, "CLIPBOARD", 0)
	x11.setSelectionOwner(display, selection, owner, x11.CurrentTime)
	x11.sync(display, x11.False)

	local started = wait.monotonic()
	test.equal(clipboard:getText(), nil)

	local waited = wait.monotonic() - started
	test.greater(waited, 0.5, "the read should have waited for the owner, not given up at once")

	x11.destroyWindow(display, owner)
	x11.closeDisplay(display)
end)

external("should read the text another program is offering", function()
	local _, clipboard = setup()

	-- The text is another program's, which is the case nothing in this process can stand in
	-- for: the selection is answered by xsel, a program of its own, while this one waits.
	test.equal(os.execute("printf 'text another program owns' | xsel -b -i"), 0)
	os.execute("sleep 0.2")

	test.equal(clipboard:getText(), "text another program owns")

	-- A second call is a second ask of the same owner, and the first one left nothing
	-- behind that would answer it by itself.
	test.equal(clipboard:getText(), "text another program owns")
end)

external("should serve the text to a program that asks for it", function()
	local eventLoop, clipboard = setup()

	local text = "served to another program"
	clipboard:setText(text)

	local out = os.tmpname()
	os.remove(out)

	-- The reader is a program of its own, so the answer has to come from the loop: nothing
	-- else in this process is running while the read below waits for it.
	os.execute("(sleep 0.1; xsel -b -o > " .. out .. " 2>/dev/null) &")

	local frames = 0
	eventLoop:run(function(_, handler)
		handler:setMode("wait")
		handler:setTimeout(0.02)

		frames = frames + 1
		if frames > 40 then
			handler:exit()
		end
	end)

	local file = io.open(out, "r")
	test.notEqual(file, nil, "the reader never wrote anything")
	---@cast file -nil

	local served = file:read("*a")
	file:close()
	os.remove(out)

	test.equal(served, text)
end)

test.it("should keep the events around a paste rather than swallowing them", function()
	local eventLoop = winit.EventLoop.new()
	local window = winit.Window.new(eventLoop, 200, 200) ---@cast window winit-x11.Window
	eventLoop:register(window)

	local display = x11.openDisplay(nil)
	test.notEqual(display, nil) ---@cast display -nil

	-- An owner that never answers, so that the read below waits -- and while it waits it is
	-- reading the display, which is where the events the loop was about to be given are.
	local root = x11.defaultRootWindow(display)
	local owner = x11.createSimpleWindow(display, root, 0, 0, 10, 10, 0, 0, 0)
	local selection = x11.internAtom(display, "CLIPBOARD", 0)
	x11.setSelectionOwner(display, selection, owner, x11.CurrentTime)
	x11.sync(display, x11.False)

	-- Three keys pressed before the loop runs, all of them queued behind the paste. The window
	-- has to be on the server, and on screen, before anything is sent to it -- which is what a
	-- round trip waits for, and what the loop would otherwise do first.
	x11.sync(eventLoop.display, x11.False)

	local keycode = 0
	for code = 8, 255 do
		if tonumber(x11.keycodeToKeysym(display, code, 0)) == 0x62 then -- the key b
			keycode = code
			break
		end
	end
	test.notEqual(keycode, 0, "the keyboard has no key b")

	for _ = 1, 3 do
		local event = x11.Event()
		event.type = x11.EventType.KeyPress
		event.xkey.window = window.id
		event.xkey.keycode = keycode
		event.xkey.state = 0

		x11.sendEvent(display, window.id, x11.False, x11.EventMaskBits.KeyPress, event)
	end
	x11.flush(display)

	local keys = {}
	local pasted = false
	local frames = 0

	eventLoop:run(function(event, handler)
		handler:setMode("poll")

		-- The paste happens in the middle of the events, which is what a program pasting from
		-- a key handler does: what the read takes off the display it has to give back.
		if not pasted then
			pasted = true
			test.equal(winit.Clipboard.new(eventLoop):getText(), nil)
		end

		if event.name == "keyPress" then
			keys[#keys + 1] = event.key
		end

		frames = frames + 1
		if #keys >= 3 or frames > 200 then
			handler:exit()
		end
	end)

	test.equal(#keys, 3, "the keys pressed around the paste should all have arrived")

	x11.destroyWindow(display, owner)
	x11.closeDisplay(display)
end)
