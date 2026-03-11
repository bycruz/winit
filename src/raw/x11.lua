local x11 = require("x11api")

---@class winit.x11.Window: winit.Window
---@field display x11.ffi.Display
---@field currentCursor number?
local X11Window = {}
X11Window.__index = X11Window

---@param eventLoop winit.x11.EventLoop
---@param width number
---@param height number
function X11Window.new(eventLoop, width, height)
	local display = eventLoop.display

	local root = x11.defaultRootWindow(display)
	if root == 0 then
		x11.closeDisplay(display)
		error("No root window found")
	end

	local id = x11.createSimpleWindow(display, root, 0, 0, width, height, 0, 0, 0x000000)
	if id == 0 then
		x11.closeDisplay(display)
		error("Failed to create window")
	end

	local window = setmetatable({ display = display, id = id, width = width, height = height }, X11Window)

	x11.setWMProtocols(display, window.id, { "WM_DELETE_WINDOW" })
	x11.selectInput(
		display,
		window.id,
		bit.bor(
			x11.EventMaskBits.Exposure,
			x11.EventMaskBits.StructureNotify,
			x11.EventMaskBits.SubstructureNotify,
			x11.EventMaskBits.ButtonPress,
			x11.EventMaskBits.ButtonRelease,
			x11.EventMaskBits.PointerMotion,
			x11.EventMaskBits.KeyPress,
			x11.EventMaskBits.KeyRelease,
			x11.EventMaskBits.FocusChange
		)
	)
	x11.mapWindow(display, window.id)

	return window
end

local keysymNames = {
	[0xff08] = "backspace",
	[0xff09] = "tab",
	[0xff0d] = "return",
	[0xff1b] = "escape",
	[0xff50] = "home",
	[0xff51] = "left",
	[0xff52] = "up",
	[0xff53] = "right",
	[0xff54] = "down",
	[0xff55] = "page-up",
	[0xff56] = "page-down",
	[0xff57] = "end",
	[0xff63] = "insert",
	[0xffff] = "delete",
	[0xffbe] = "f1",
	[0xffbf] = "f2",
	[0xffc0] = "f3",
	[0xffc1] = "f4",
	[0xffc2] = "f5",
	[0xffc3] = "f6",
	[0xffc4] = "f7",
	[0xffc5] = "f8",
	[0xffc6] = "f9",
	[0xffc7] = "f10",
	[0xffc8] = "f11",
	[0xffc9] = "f12",
	[0xffe1] = "left-shift",
	[0xffe2] = "right-shift",
	[0xffe3] = "left-ctrl",
	[0xffe4] = "right-ctrl",
	[0xffe9] = "left-alt",
	[0xffea] = "right-alt",
	[0xffeb] = "left-super",
	[0xffec] = "right-super",
	[0xffe5] = "caps-lock",
}

---@param keysym number
---@param char string
---@return winit.KeyName?
local function keysymToKey(keysym, char)
	local named = keysymNames[keysym]
	if named then return named end
	if #char > 0 then return char end
	return nil
end

local function keyModifiers(state)
	return {
		shift = bit.band(state, 1) ~= 0,
		lock  = bit.band(state, 2) ~= 0,
		ctrl  = bit.band(state, 4) ~= 0,
		alt   = bit.band(state, 8) ~= 0,
		super = bit.band(state, 64) ~= 0,
	}
end

local cursors = {
	pointer = x11.Icon.LeftPtr,
	hand2 = x11.Icon.Hand2,
}

---@param shape "pointer" | "hand2"
function X11Window:setCursor(shape)
	if self.currentCursor then
		x11.freeCursor(self.display, self.currentCursor)
	end

	local cursor = x11.createFontCursor(self.display, cursors[shape])
	x11.defineCursor(self.display, self.id, cursor)
	self.currentCursor = cursor
end

function X11Window:resetCursor()
	if self.currentCursor then
		x11.freeCursor(self.display, self.currentCursor)
		self.currentCursor = nil
	end

	x11.undefineCursor(self.display, self.id)
end

---@param title string
function X11Window:setTitle(title)
	x11.changeProperty(self.display, self.id, "_NET_WM_NAME", "UTF8_STRING", 8, 0, title, #title)
	x11.flush(self.display)
end

function X11Window:destroy()
	if self.currentCursor then
		x11.freeCursor(self.display, self.currentCursor)
	end

	x11.destroyWindow(self.display, self.id)
end

---@class winit.x11.EventLoop: winit.EventLoop
---@field display x11.ffi.Display
local X11EventLoop = {}
X11EventLoop.__index = X11EventLoop

function X11EventLoop.new()
	local display = x11.openDisplay(nil)
	if display == nil then
		error("Failed to open X11 display")
	end

	return setmetatable({ display = display, windows = {} }, X11EventLoop)
end

---@param window winit.Window
function X11EventLoop:register(window)
	self.windows[tostring(window.id)] = window
end

---@param window winit.Window
function X11EventLoop:close(window)
	window:destroy()
	self.windows[tostring(window.id)] = nil
end

---@param callback winit.EventHandler
function X11EventLoop:run(callback)
	local display = self.display
	local event = x11.Event()

	local wmDeleteWindow = x11.internAtom(display, "WM_DELETE_WINDOW", 0)

	local isActive = true
	local currentMode = "poll"

	---@type winit.EventManager
	local handler = {}
	do
		function handler:exit()
			isActive = false
		end

		function handler:setMode(mode)
			currentMode = mode
		end

		function handler:requestRedraw(window)
			window.shouldRedraw = true
		end

		function handler.close(_, window)
			self:close(window)
		end
	end

	---@type table<number, fun(window: winit.Window)>
	local Handlers = {
		[x11.EventType.MotionNotify] = function(window)
			callback({ window = window, name = "mouseMove", x = event.xmotion.x, y = event.xmotion.y }, handler)
		end,

		[x11.EventType.ClientMessage] = function(window)
			if event.xclient.data.l[0] == wmDeleteWindow then
				callback({ window = window, name = "windowClose" }, handler)
			end
		end,

		[x11.EventType.Expose] = function(window)
			callback({ window = window, name = "redraw" }, handler)
		end,

		[x11.EventType.DestroyNotify] = function(window) end,

		[x11.EventType.ConfigureNotify] = function(window)
			local newWidth = event.xconfigure.width
			local newHeight = event.xconfigure.height

			if newWidth ~= window.width or newHeight ~= window.height then
				window.width = newWidth
				window.height = newHeight
				callback({ window = window, name = "resize" }, handler)
			else -- Move event?
				-- Ignored for now
			end
		end,

		[x11.EventType.MapNotify] = function(window)
			callback({ window = window, name = "map" }, handler)
		end,

		[x11.EventType.UnmapNotify] = function(window)
			callback({ window = window, name = "unmap" }, handler)
		end,

		[x11.EventType.CreateNotify] = function(window)
			callback({ window = window, name = "create" }, handler)
		end,

		[x11.EventType.ButtonPress] = function(window)
			callback({
				window = window,
				name = "mousePress",
				x = event.xbutton.x,
				y = event.xbutton.y,
				button = event.xbutton.button,
			}, handler)
		end,

		[x11.EventType.ButtonRelease] = function(window)
			callback({
				window = window,
				name = "mouseRelease",
				x = event.xbutton.x,
				y = event.xbutton.y,
				button = event.xbutton.button,
			}, handler)
		end,

		[x11.EventType.FocusIn] = function(window)
			callback({ window = window, name = "focusIn" }, handler)
		end,

		[x11.EventType.FocusOut] = function(window)
			callback({ window = window, name = "focusOut" }, handler)
		end,

		[x11.EventType.KeyPress] = function(window)
			local char, keysym = x11.lookupString(event)
			local key = keysymToKey(tonumber(keysym), char)
			if key then
				callback({
					window = window,
					name = "keyPress",
					key = key,
					modifiers = keyModifiers(event.xkey.state),
				}, handler)
			end
		end,

		[x11.EventType.KeyRelease] = function(window)
			local char, keysym = x11.lookupString(event)
			local key = keysymToKey(tonumber(keysym), char)
			if key then
				callback({
					window = window,
					name = "keyRelease",
					key = key,
					modifiers = keyModifiers(event.xkey.state),
				}, handler)
			end
		end,
	}

	local function processEvent()
		local windowIdHash = tostring(event.xany.window)
		local window = self.windows[windowIdHash]

		local evtTypeHandler = Handlers[event.type]
		if not evtTypeHandler then
			print("Warning: Unhandled X11 event type: " .. tostring(event.type))
		else
			evtTypeHandler(window)
		end
	end

	local function coalesceMouse()
		if x11.pending(display) == 0 then
			return
		end

		local tempEvent = x11.Event()
		local hasMoreMotion = true

		while hasMoreMotion and x11.pending(display) > 0 do
			x11.peekEvent(display, tempEvent)
			if tempEvent.type == x11.EventType.MotionNotify and tempEvent.xmotion.window == event.xmotion.window then
				x11.nextEvent(display, event)
			else
				hasMoreMotion = false
			end
		end
	end

	local redrawEvent = { name = "redraw" }
	local aboutToWaitEvent = { name = "aboutToWait" }

	while isActive do
		if currentMode == "poll" then
			if x11.pending(display) > 0 then
				x11.nextEvent(display, event)
				if event.type == x11.EventType.MotionNotify then
					coalesceMouse()
				end

				processEvent()
			end
		else
			x11.nextEvent(display, event)
			if event.type == x11.EventType.MotionNotify then
				coalesceMouse()
			end

			processEvent()
		end

		for _, window in pairs(self.windows) do
			if window.shouldRedraw then
				window.shouldRedraw = false
				redrawEvent.window = window
				callback(redrawEvent, handler)
			end
		end

		callback(aboutToWaitEvent, handler)
	end
end

return { Window = X11Window, EventLoop = X11EventLoop }
