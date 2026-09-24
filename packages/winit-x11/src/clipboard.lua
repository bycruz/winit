local ffi = require("ffi")
local x11 = require("x11api")
local wait = require("winit-x11.wait")

--- How long a read waits for the clipboard's owner to answer, in seconds. Reading a selection is
--- a conversation with another program, and one that never answers -- hung, or killed with the
--- request still in flight -- would leave a paste waiting on it for good. Past this the
--- clipboard is taken to hold nothing, which is something a program can carry on from.
local REPLY_TIMEOUT = 1.0

---@class winit-x11.Clipboard: winit.Clipboard
---@field display x11.ffi.Display
---@field eventLoop winit-x11.EventLoop
---@field window number # The unmapped window that owns the clipboard and answers for it
---@field text string? # What this clipboard is offering, or nothing when it offers nothing
---@field atoms table<string, number>
local Clipboard = {}
Clipboard.__index = Clipboard

--- The atom a name stands for, interned once and remembered.
---@param self winit-x11.Clipboard
---@param name string
---@return number
local function atom(self, name)
	local interned = self.atoms[name]
	if not interned then
		interned = x11.internAtom(self.display, name, 0)
		self.atoms[name] = interned
	end

	return interned
end

--- The same text in the bytes X11 calls STRING. What that is, is Latin-1: one byte a
--- character, where what a LuaJIT string holds is UTF-8, where a character past the first 127
--- is two. A clipboard asked for the older target is answered in it, so what comes back is
--- converted rather than handed over as bytes that would read as mojibake.
---@param text string
---@return string
local function latin1ToUtf8(text)
	local converted = {}

	for i = 1, #text do
		local byte = string.byte(text, i)
		if byte < 0x80 then
			converted[#converted + 1] = string.char(byte)
		else
			converted[#converted + 1] = string.char(0xC0 + math.floor(byte / 64), 0x80 + byte % 64)
		end
	end

	return table.concat(converted)
end

--- Whether text is bytes the older STRING target can carry as they are: it holds Latin-1, and
--- UTF-8 bytes only read as Latin-1 when they are the first 127 of them.
---@param text string
---@return boolean
local function isAscii(text)
	return text:find("[\128-\255]") == nil
end

---@param eventLoop winit-x11.EventLoop
---@return winit-x11.Clipboard
function Clipboard.new(eventLoop)
	local display = eventLoop.display
	local root = x11.defaultRootWindow(display)

	-- A selection is offered by a window, and the requests for it arrive as events, so the
	-- clipboard needs one of its own: the loop is where those are read, and a window nobody
	-- meant to see is the one thing that belongs to the clipboard itself rather than to any
	-- window a program put on screen -- a paste is a paste wherever it lands.
	local window = x11.createSimpleWindow(display, root, 0, 0, 1, 1, 0, 0, 0)
	if window == 0 then
		error("Failed to create the clipboard's window")
	end

	local self = setmetatable({
		display = display,
		eventLoop = eventLoop,
		window = window,
		text = nil,
		atoms = {},
	}, Clipboard)

	-- the loop answers for whichever clipboard was made last on it, which is the one a program
	-- holding the handle is talking to
	eventLoop.clipboard = self

	return self
end

--- Offers text to the rest of the system, which reads it out of this program while it runs:
--- owning a selection is offering to be asked, and what is asked for is answered from the loop.
---@param text string
function Clipboard:setText(text)
	self.text = text

	local clipboard = atom(self, "CLIPBOARD")
	x11.setSelectionOwner(self.display, clipboard, self.window, x11.CurrentTime)
	x11.flush(self.display)
end

--- Empties the clipboard, which X11 says by there being no owner of it at all -- so what is
--- given up is the ownership, and with it whatever this program was offering.
function Clipboard:clear()
	self.text = nil

	local clipboard = atom(self, "CLIPBOARD")
	x11.setSelectionOwner(self.display, clipboard, 0, x11.CurrentTime)
	x11.flush(self.display)
end

--- Asks the clipboard's owner for a target, and hands back what it wrote, or nothing when it
--- answered with nothing -- which is what an owner that does not speak that target does. The
--- type it wrote it as comes back too, which is what says whether the bytes are UTF-8, and
--- whether the owner answered at all: an owner that did not is one there is no point asking
--- anything else, while one that answered with nothing is one to ask in other words.
---@param clipboard number
---@param target number
---@return string? data
---@return number storedAs
---@return boolean answered
function Clipboard:request(clipboard, target)
	local event = x11.Event()

	x11.convertSelection(self.display, clipboard, target, target, self.window, x11.CurrentTime)
	x11.flush(self.display)

	if not self:waitForNotify(event, clipboard, target) then
		return nil, 0, false
	end

	-- property None: the owner was asked for something it does not have
	if event.xselection.property == 0 then
		return nil, 0, true
	end

	local data, storedAs = x11.getProperty(self.display, self.window, target, true)
	return data, storedAs, true
end

--- Waits, up to a time, for the answer to a conversion request, and hands back whether it came.
--- What the wait reads of everything else -- a key pressed while a paste was asked for -- is
--- kept for the loop to hand over once this is done, so a program that pastes is not a program
--- that loses the events around it.
---@param event x11.ffi.Event # where the answer is left for the caller to read
---@param clipboard number
---@param target number
---@return boolean
function Clipboard:waitForNotify(event, clipboard, target)
	local display = self.display
	local deadline = wait.monotonic() + REPLY_TIMEOUT

	while true do
		while x11.pending(display) > 0 do
			x11.nextEvent(display, event)

			if event.type == x11.EventType.SelectionNotify then
				local notify = event.xselection
				if notify.requestor == self.window
					and notify.selection == clipboard
					and notify.target == target then
					return true
				end

				self:keep(event)
			elseif event.type == x11.EventType.SelectionRequest then
				-- safety: a program waiting on a paste can still be asked for one of its own,
				-- and it is the owner of that one -- answering is what keeps the other program
				-- from waiting on an answer that would only come once this one is done
				self:handleRequest(event)
			elseif event.type == x11.EventType.SelectionClear then
				self:handleClear(event)
			else
				self:keep(event)
			end
		end

		local left = deadline - wait.monotonic()
		if left <= 0 then
			return false
		end

		wait.readable(display, math.ceil(left * 1000))
	end
end

--- Keeps an event back for the loop, which is where events belong: one read here would
--- otherwise be one the program never hears about.
---@param event x11.ffi.Event
function Clipboard:keep(event)
	local kept = x11.Event()
	ffi.copy(kept, event, ffi.sizeof(event))

	local stash = self.eventLoop.stashedEvents
	stash[#stash + 1] = kept
end

--- Answers a program asking for what this clipboard is offering, which is the other half of
--- owning it: the data is written where it asked, and it is told to look there.
---@param event x11.ffi.Event
function Clipboard:handleRequest(event)
	local display = self.display
	local request = event.xselectionrequest

	-- safety: a request for a selection this clipboard does not own is not this one's to
	-- answer, and answering it with nothing would be a lie about what it holds
	if request.selection ~= atom(self, "CLIPBOARD") then
		return
	end

	local reply = x11.Event()
	reply.xselection.type = x11.EventType.SelectionNotify
	reply.xselection.display = display
	reply.xselection.requestor = request.requestor
	reply.xselection.selection = request.selection
	reply.xselection.target = request.target
	reply.xselection.time = request.time
	reply.xselection.property = 0

	-- an old requestor may leave the property unnamed, in which case the target is its name
	local property = request.property ~= 0 and request.property or request.target
	local target = request.target
	local ascii = self.text ~= nil and isAscii(self.text)

	if target == atom(self, "TARGETS") then
		-- what this clipboard can be asked for, which includes the question being asked
		local targets = { atom(self, "TARGETS") }
		if self.text then
			targets[#targets + 1] = atom(self, "UTF8_STRING")
			if ascii then
				targets[#targets + 1] = x11.XA.STRING
			end
		end

		x11.setAtomProperty(display, request.requestor, property, x11.XA.ATOM, targets)
		reply.xselection.property = property
	elseif self.text and (target == atom(self, "UTF8_STRING") or (target == x11.XA.STRING and ascii)) then
		x11.setProperty(display, request.requestor, property, target, 8, x11.PropMode.Replace,
			self.text, #self.text)
		reply.xselection.property = property
	end

	x11.sendEvent(display, request.requestor, x11.False, 0, reply)
	x11.flush(display)
end

--- Someone else took the clipboard: what was offered is no longer what a paste gets, and
--- saying so is the difference between an honest answer and a stale one.
---@param event x11.ffi.Event
function Clipboard:handleClear(event)
	if event.xselection.selection ~= atom(self, "CLIPBOARD") then
		return
	end

	self.text = nil
end

--- What the clipboard holds, asked of whichever program owns it -- which is this one, when the
--- text being pasted is the text this program put there.
---@return string?
function Clipboard:getText()
	local clipboard = atom(self, "CLIPBOARD")

	-- safety: when the clipboard is this program's own, the answer is what was put there.
	-- Asking the server for it would come back as a request to this very window, and the loop
	-- that answers those is not running while a caller waits inside it.
	if x11.getSelectionOwner(self.display, clipboard) == self.window then
		return self.text
	end

	local utf8 = atom(self, "UTF8_STRING")
	local data, storedAs, answered = self:request(clipboard, utf8)

	if not data and answered then
		-- UTF8_STRING is what everything that is not ancient speaks. An owner that answered
		-- nothing is one from before it, and the older target is what it does speak. One that
		-- did not answer at all is not to be waited on twice.
		data, storedAs = self:request(clipboard, x11.XA.STRING)
		if not data then
			return nil
		end
	end

	-- An owner is asked for UTF8_STRING and may answer with the older encoding anyway, which
	-- is what its type says: only one of the two is bytes that are already UTF-8.
	if storedAs == utf8 then
		return data
	elseif storedAs == x11.XA.STRING then
		return latin1ToUtf8(data)
	end

	return nil
end

return Clipboard
