local test = require("lde-test")

if jit.os ~= "Linux" then
	-- A drag is the display's to deliver, and this package has no other way of getting one:
	-- the monorepo's tests run every package on every platform, so this one says what it is
	-- rather than looking like a file that registered nothing at all.
	test.skip("x11 drag and drop tests (skipped: not Linux)")
	return
end

local bit = require("bit")
local x11 = require("x11api")
local winit = require("winit-x11")
local Dnd = require("winit-x11.dnd")

test.it("should read the paths out of a URI list", function()
	-- One URI a line, and what a drag hands over is files on this machine: a host that is
	-- not this one names something this program cannot open.
	test.deepEqual(Dnd.parseUriList("file:///home/once/a.txt\r\nfile://localhost/home/once/b.txt\n"),
		{ "/home/once/a.txt", "/home/once/b.txt" })

	-- A path is escaped, because a URI has no room for a space, a `#`, or any byte that is
	-- not ASCII -- and what an app wants back is the path, unescaped.
	test.deepEqual(Dnd.parseUriList("file:///home/once/a%20file%20%23%202.txt"), { "/home/once/a file # 2.txt" })
	test.deepEqual(Dnd.parseUriList("file:///home/once/%C3%A9t%C3%A9.txt"), { "/home/once/été.txt" })

	-- A list is a text file, and a text file may explain itself.
	test.deepEqual(Dnd.parseUriList("# this is a comment\r\nfile:///tmp/real.txt\r\n"), { "/tmp/real.txt" })

	-- Other schemes and other machines are not paths here, and a list of nothing is not a
	-- failure: it is a drop that carried nothing an app can open.
	test.deepEqual(Dnd.parseUriList("https://example.com/file.txt"), {})
	test.deepEqual(Dnd.parseUriList("file://elsewhere.example.com/tmp/file.txt"), {})
	test.deepEqual(Dnd.parseUriList(""), {})
end)

--- Two halves of a point packed into the 32 bits the protocol packs them in.
---@param high number
---@param low number
---@return number
local function pack16(high, low)
	return bit.bor(bit.lshift(bit.band(high, 0xFFFF), 16), bit.band(low, 0xFFFF))
end

--- What a program doing the dragging sends the window it is over.
---@param display x11.ffi.Display
---@param window number
---@param messageType number
---@param values number[]
local function sendClientMessage(display, window, messageType, values)
	local event = x11.Event()
	event.xclient.type = x11.EventType.ClientMessage
	event.xclient.window = window
	event.xclient.message_type = messageType
	event.xclient.format = 32

	for i, value in ipairs(values) do
		event.xclient.data.l[i - 1] = value
	end

	x11.sendEvent(display, window, x11.False, 0, event)
	x11.flush(display)
end

--- The names every drag on a display is spoken in, interned once for a test.
---@param display x11.ffi.Display
---@return table<string, number>
local function internDndAtoms(display)
	local names = {
		"XdndEnter", "XdndPosition", "XdndDrop", "XdndStatus", "XdndFinished", "XdndSelection",
		"XdndActionCopy", "text/uri-list", "UTF8_STRING",
	}

	local atoms = {}
	local interned = x11.internAtoms(display, names)
	for i, name in ipairs(names) do
		atoms[name] = interned[i]
	end

	return atoms
end

--- What the socket of a second connection is holding, which is what a program doing the
--- dragging would be reading as the window under it answers it. `answer` is handed every
--- request for the files, and what the source hears is left in `state`.
---@param display x11.ffi.Display
---@param atoms table<string, number>
---@param state table
---@param answer fun(request: x11.ffi.SelectionRequestEvent)? # What to put where the target asked
---@return number
local function readSource(display, atoms, state, answer)
	local read = 0

	while x11.pending(display) > 0 do
		local seen = x11.Event()
		x11.nextEvent(display, seen)
		read = read + 1

		if seen.type == x11.EventType.SelectionRequest and answer then
			answer(seen.xselectionrequest)
		elseif seen.type == x11.EventType.ClientMessage and seen.xclient.message_type == atoms.XdndStatus then
			state.statusWindow = seen.xclient.data.l[0]
			state.statusAccepted = bit.band(seen.xclient.data.l[1], 1) == 1
			state.statusRectangle = { seen.xclient.data.l[2], seen.xclient.data.l[3] }
		elseif seen.type == x11.EventType.ClientMessage and seen.xclient.message_type == atoms.XdndFinished then
			state.finishedWindow = seen.xclient.data.l[0]
			state.finishedSuccess = bit.band(seen.xclient.data.l[1], 1) == 1
		end
	end

	return read
end

test.it("should take the files a drag drops on a window", function()
	local eventLoop = winit.EventLoop.new()
	local window = winit.Window.new(eventLoop, 200, 200) ---@cast window winit-x11.Window
	eventLoop:register(window)

	-- The program doing the dragging is another client of the display, which is what makes
	-- the exchange below the protocol rather than a call into this package.
	local display = x11.openDisplay(nil)
	test.notEqual(display, nil) ---@cast display -nil

	local root = x11.defaultRootWindow(display)
	local source = x11.createSimpleWindow(display, root, 0, 0, 10, 10, 0, 0, 0)
	local atoms = internDndAtoms(display)

	-- What the drag is carrying, read out of the source when the drop is taken.
	local uriList = "file:///home/once/dropped%20file.txt\r\nfile:///home/once/second.txt\r\n"

	-- The source owns the selection the files travel in, and tells the window under it that
	-- the drag is there, where it is standing, and that it has been let go of.
	x11.setSelectionOwner(display, atoms.XdndSelection, source, x11.CurrentTime)
	x11.sync(display, x11.False)

	-- Where the window sits on the screen, so the position sent below is a point of it a
	-- drag would be standing over -- a window manager is free to have moved it.
	local windowX, windowY = x11.translateCoordinates(display, window.id, root, 0, 0)
	local atX, atY = 60, 40

	sendClientMessage(display, window.id, atoms.XdndEnter, {
		source, bit.lshift(5, 24), atoms["text/uri-list"],
	})
	sendClientMessage(display, window.id, atoms.XdndPosition, {
		source, 0, pack16(windowX + atX, windowY + atY), 0, atoms.XdndActionCopy,
	})
	sendClientMessage(display, window.id, atoms.XdndDrop, { source, 0, 0 })

	local state = {}
	local dropped = nil
	local frames = 0

	--- Puts the files where the target asked for them, which is what the program doing the
	--- dragging does with the selection it owns, and tells it to look there.
	---@param request x11.ffi.SelectionRequestEvent
	local function answer(request)
		x11.setProperty(display, request.requestor, request.property, atoms.UTF8_STRING, 8,
			x11.PropMode.Replace, uriList, #uriList)

		local reply = x11.Event()
		reply.xselection.type = x11.EventType.SelectionNotify
		reply.xselection.requestor = request.requestor
		reply.xselection.selection = request.selection
		reply.xselection.target = request.target
		reply.xselection.property = request.property
		reply.xselection.time = request.time

		x11.sendEvent(display, request.requestor, x11.False, 0, reply)
		x11.flush(display)
	end

	eventLoop:run(function(event, handler)
		handler:setMode("poll")

		readSource(display, atoms, state, answer)

		if event.name == "fileDrop" then
			dropped = event
		end

		frames = frames + 1
		if dropped or frames > 200 then
			handler:exit()
		end
	end)

	-- The word the source is owed travels after the drop does, and a sync is what waits for
	-- the server to have taken it.
	x11.sync(eventLoop.display, x11.False)
	readSource(display, atoms, state, answer)

	test.notEqual(dropped, nil, "the drop never reached the program")
	---@cast dropped -nil
	test.equal(dropped.window, window)
	test.deepEqual(dropped.paths, { "/home/once/dropped file.txt", "/home/once/second.txt" })

	-- The position a drop is reported at is where the drag was, in the window's own corner,
	-- which is the same corner every other position an event carries is measured in.
	test.equal(dropped.x, atX)
	test.equal(dropped.y, atY)

	test.equal(state.statusAccepted, true, "a window should have said a drop here is welcome")
	test.equal(state.statusWindow, window.id, "the status belongs to the window it is about")
	test.equal(state.finishedWindow, window.id)
	test.equal(state.finishedSuccess, true, "the source should be told the files arrived")

	x11.destroyWindow(display, source)
	x11.closeDisplay(display)
end)

test.it("should say where a drop is welcome and what became of one it did not take", function()
	local eventLoop = winit.EventLoop.new()
	local window = winit.Window.new(eventLoop, 200, 200) ---@cast window winit-x11.Window
	eventLoop:register(window)

	local display = x11.openDisplay(nil)
	test.notEqual(display, nil) ---@cast display -nil

	local root = x11.defaultRootWindow(display)
	local source = x11.createSimpleWindow(display, root, 0, 0, 10, 10, 0, 0, 0)
	local atoms = internDndAtoms(display)

	x11.setSelectionOwner(display, atoms.XdndSelection, source, x11.CurrentTime)
	x11.sync(display, x11.False)

	-- The window is asked where a drop would land before anything is dropped, and what it
	-- answers decides whether the drag is welcome: a window that never answers is one a drag
	-- hovers over and cannot end on.
	sendClientMessage(display, window.id, atoms.XdndEnter, {
		source, bit.lshift(5, 24), atoms["text/uri-list"],
	})
	sendClientMessage(display, window.id, atoms.XdndPosition, {
		source, 0, pack16(10, 10), 0, atoms.XdndActionCopy,
	})

	local state = {}
	local frames = 0
	local dropped = false
	local sentDrop = false

	--- Says nothing at all about the files, which is what an owner with nothing to hand over
	--- answers with -- the same shape of answer as one that cannot read what it was asked.
	---@param request x11.ffi.SelectionRequestEvent
	local function refuse(request)
		local reply = x11.Event()
		reply.xselection.type = x11.EventType.SelectionNotify
		reply.xselection.requestor = request.requestor
		reply.xselection.selection = request.selection
		reply.xselection.target = request.target
		reply.xselection.property = 0
		reply.xselection.time = request.time

		x11.sendEvent(display, request.requestor, x11.False, 0, reply)
		x11.flush(display)
	end

	eventLoop:run(function(event, handler)
		handler:setMode("poll")

		readSource(display, atoms, state, refuse)

		-- The drop is let go of once the window has said it is welcome, which is what a
		-- program doing the dragging does with the answer it was given.
		if state.statusAccepted ~= nil and not sentDrop then
			sentDrop = true
			sendClientMessage(display, window.id, atoms.XdndDrop, { source, 0, 0 })
		end

		if event.name == "fileDrop" then
			dropped = true
		end

		frames = frames + 1
		if frames > 200 then
			handler:exit()
		end
	end)

	x11.sync(eventLoop.display, x11.False)
	readSource(display, atoms, state, refuse)

	test.equal(state.statusAccepted, true, "a window should welcome files")
	test.notEqual(state.statusRectangle, nil)
	test.equal(state.statusRectangle[1], 0, "the rectangle a drop is welcome in starts at its corner")
	test.equal(bit.rshift(bit.band(state.statusRectangle[2], 0xFFFFFFFF), 16), window.width)
	test.equal(bit.band(state.statusRectangle[2], 0xFFFF), window.height)

	-- A drop whose files could not be read is one the program is not handed, and the source
	-- is told so rather than left waiting.
	test.equal(dropped, false, "a drop of nothing is not a drop a program can do anything with")
	test.equal(state.finishedSuccess, false, "the source should be told the drop was not taken")

	x11.destroyWindow(display, source)
	x11.closeDisplay(display)
end)
