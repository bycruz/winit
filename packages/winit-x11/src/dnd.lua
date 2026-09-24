local x11 = require("x11api")

--- The version of the drag protocol this target speaks. Five is the one where the program doing
--- the dragging is told what became of the drop, so it can end its own half of it instead of
--- guessing; a source older than that simply never hears.
local VERSION = 5

--- The formats a window of this program offers to be dropped on. What a drop carries is a list
--- of files, which X11 describes the way it describes everything handed between programs: as a
--- URI list, whose lines name files this machine can open.
local URI_LIST = "text/uri-list"

--- Two 16-bit halves of a 32-bit value, which is how the protocol packs a point into one.
---@param high number
---@param low number
---@return number
local function pack16(high, low)
	return bit.bor(bit.lshift(bit.band(high, 0xFFFF), 16), bit.band(low, 0xFFFF))
end

--- ... and back, with the sign the protocol means by them: a point can sit to the left of or
--- above the root window's corner, which is where a second screen is.
---@param packed number
---@return number high, number low
local function unpack16(packed)
	local high = bit.band(bit.rshift(packed, 16), 0xFFFF)
	local low = bit.band(packed, 0xFFFF)

	if high >= 0x8000 then high = high - 0x10000 end
	if low >= 0x8000 then low = low - 0x10000 end

	return high, low
end

---@class winit-x11.Dnd
---@field display x11.ffi.Display
---@field atoms table<string, number>
---@field source number? # The window of the program dragging, while one is over a window of ours
---@field version number # The version that program speaks
---@field types number[] # The formats it is offering
---@field accepted boolean # Whether a file list was among them
---@field window winit-x11.Window? # The window it is over
---@field x number # Where it is, in the root window's coordinates
---@field y number
local Dnd = {}
Dnd.__index = Dnd

--- The paths in a URI list: one per line, `#` starting a comment, and a path escaped, because a
--- URI has no room for the characters a file name is allowed to hold -- a space, a `#`, or any
--- byte that is not ASCII. What a drop hands an app is the paths, decoded.
---@param text string
---@return string[]
function Dnd.parseUriList(text)
	local paths = {}

	for line in text:gmatch("[^\r\n]+") do
		-- safety: the list is a text file, and a text file may explain itself
		if line:sub(1, 1) ~= "#" then
			local path = Dnd.uriToPath(line)
			if path then
				paths[#paths + 1] = path
			end
		end
	end

	return paths
end

--- The path a file URI names, or nothing when it does not name one on this machine: a drag
--- between two programs on the same display is about files that are here, so a host that is not
--- this one is a path this program cannot open.
---@param uri string
---@return string?
function Dnd.uriToPath(uri)
	local host, path = uri:match("^file://([^/]*)(/.*)$")
	if not path then
		return nil
	end

	if host ~= "" and host ~= "localhost" then
		return nil
	end

	return (path:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

---@param eventLoop winit-x11.EventLoop
---@return winit-x11.Dnd
function Dnd.new(eventLoop)
	local display = eventLoop.display

	local names = {
		"XdndAware", "XdndEnter", "XdndPosition", "XdndStatus", "XdndLeave", "XdndDrop",
		"XdndFinished", "XdndSelection", "XdndTypeList", "XdndActionCopy", URI_LIST,
	}

	local atoms = {}
	local interned = x11.internAtoms(display, names)
	for i, name in ipairs(names) do
		atoms[name] = interned[i]
	end

	return setmetatable({
		display = display,
		atoms = atoms,
		source = nil,
		version = 0,
		types = {},
		accepted = false,
		window = nil,
		x = 0,
		y = 0,
	}, Dnd)
end

--- Says a window can be dropped on. A drag is a conversation the two programs have about a
--- window, and this property is what starts it: without it the program doing the dragging has
--- no way of knowing there is anything here that wants what it is carrying.
---@param window number
function Dnd:aware(window)
	x11.setAtomProperty(self.display, window, self.atoms.XdndAware, x11.XA.ATOM, { VERSION })
end

---@return boolean # Whether a file list is among what the drag is offering
function Dnd:offersFiles()
	for _, offered in ipairs(self.types) do
		if offered == self.atoms[URI_LIST] then
			return true
		end
	end

	return false
end

--- A drag has come over a window of ours, and says what it is carrying.
---@param window winit-x11.Window
---@param client x11.ffi.ClientMessageEvent
function Dnd:enter(window, client)
	local version = bit.rshift(client.data.l[1], 24)
	local more = bit.band(client.data.l[1], 1) ~= 0

	self.source = client.data.l[0]
	self.version = version
	self.window = window
	self.types = {}

	if more and version >= 5 then
		-- more formats than the message had room for, and the rest were left on a property of
		-- the source's own window -- which is the one place the protocol says to look
		local list = x11.getAtomProperty(self.display, self.source, self.atoms.XdndTypeList, false)
		if list then
			self.types = list
		end
	else
		for i = 2, 4 do
			local offered = client.data.l[i]
			if offered ~= 0 then
				self.types[#self.types + 1] = offered
			end
		end
	end

	self.accepted = self:offersFiles()
end

--- The drag has moved, and where it is standing is where a drop would land.
---@param window winit-x11.Window
---@param client x11.ffi.ClientMessageEvent
function Dnd:position(window, client)
	if client.data.l[0] ~= self.source then
		return
	end

	self.window = window
	self.x, self.y = unpack16(client.data.l[2])

	self:status()
end

--- Says whether a drop here is welcome, and where. A position left unanswered is a drag left
--- hovering over a window that never answered it, which is a drag that cannot end.
function Dnd:status()
	local window = self.window
	if not window then
		return
	end

	local reply = x11.Event()
	reply.xclient.type = x11.EventType.ClientMessage
	reply.xclient.window = self.source
	reply.xclient.message_type = self.atoms.XdndStatus
	reply.xclient.format = 32
	reply.xclient.data.l[0] = window.id
	reply.xclient.data.l[1] = self.accepted and 1 or 0
	-- the rectangle a drop is welcome in, which is all of the window
	reply.xclient.data.l[2] = pack16(0, 0)
	reply.xclient.data.l[3] = pack16(window.width, window.height)
	reply.xclient.data.l[4] = self.accepted and self.atoms.XdndActionCopy or 0

	x11.sendEvent(self.display, self.source, x11.False, 0, reply)
	x11.flush(self.display)
end

--- The drag was dropped, and what it carries is asked for by name -- the same door a clipboard
--- read goes through, answered later, by the source, as an event of its own.
---@param window winit-x11.Window
---@param client x11.ffi.ClientMessageEvent
function Dnd:drop(window, client)
	if client.data.l[0] ~= self.source then
		return
	end

	self.window = window

	local target = self.atoms[URI_LIST]
	x11.convertSelection(self.display, self.atoms.XdndSelection, target, target, window.id,
		client.data.l[2])
	x11.flush(self.display)
end

--- The drag left without dropping, so there is nothing to answer and nothing to remember.
function Dnd:leave()
	self.source = nil
	self.window = nil
	self.types = {}
	self.accepted = false
end

--- Tells the source what became of its drop, which is what version five of the protocol is
--- for: the files were handed over, or they were not, and either way it can stop waiting.
---@param window winit-x11.Window
---@param success boolean
function Dnd:finished(window, success)
	if self.version < 5 or not self.source then
		return
	end

	local reply = x11.Event()
	reply.xclient.type = x11.EventType.ClientMessage
	reply.xclient.window = self.source
	reply.xclient.message_type = self.atoms.XdndFinished
	reply.xclient.format = 32
	reply.xclient.data.l[0] = window.id
	reply.xclient.data.l[1] = success and 1 or 0
	reply.xclient.data.l[2] = success and self.atoms.XdndActionCopy or 0

	x11.sendEvent(self.display, self.source, x11.False, 0, reply)
	x11.flush(self.display)
end

---@param window winit-x11.Window?
---@param event x11.ffi.Event
---@param callback winit.EventHandler
---@param handler winit.EventManager
---@return boolean # Whether this was one of the drag protocol's messages
function Dnd:handleClientMessage(window, event, callback, handler)
	local message = event.xclient.message_type

	if message == self.atoms.XdndEnter then
		if window then self:enter(window, event.xclient) end
		return true
	elseif message == self.atoms.XdndPosition then
		if window then self:position(window, event.xclient) end
		return true
	elseif message == self.atoms.XdndDrop then
		if window then self:drop(window, event.xclient) end
		return true
	elseif message == self.atoms.XdndLeave then
		self:leave()
		return true
	end

	return false
end

--- What the source wrote when it was asked for the files it dropped: the paths to hand an app,
--- and the word the source is owed that they arrived.
---@param event x11.ffi.Event
---@param callback winit.EventHandler
---@param handler winit.EventManager
function Dnd:handleSelectionNotify(event, callback, handler)
	local notify = event.xselection

	if notify.selection ~= self.atoms.XdndSelection then
		return
	end

	local window = self.window
	local source = self.source

	if not window or not source or notify.requestor ~= window.id then
		self:leave()
		return
	end

	-- safety: a source that answered with nothing had nothing this window asked for, and a
	-- drop of nothing is not a drop a program can do anything with
	if notify.property == 0 then
		self:finished(window, false)
		self:leave()
		return
	end

	local list = x11.getProperty(self.display, notify.requestor, notify.property, true)
	local paths = list and Dnd.parseUriList(list) or {}

	local x, y = x11.translateCoordinates(self.display, x11.defaultRootWindow(self.display),
		window.id, self.x, self.y)

	self:finished(window, true)
	self:leave()

	callback({ window = window, name = "fileDrop", paths = paths, x = x, y = y }, handler)
end

return Dnd
