local ffi = require("ffi")
local user32 = require("winapi.user32")
local kernel32 = require("winapi.kernel32")
local shell32 = require("winapi.shell32")
local Clipboard = require("winit-win32.clipboard")
local readDrop = require("winit-win32.drop")

--- Casts a ffi pointer to a lua number for use as a hash key.
---@param value ffi.cdata*
local function ffiptrToDouble(value)
	return tonumber(ffi.cast("intptr_t", value))
end

---@class winit-win32.Window: winit.Window
---@field display winapi.user32.ffi.HDC
---@field id ffi.cdata*
---@field hwnd winapi.user32.ffi.HWND
---@field currentCursor ffi.cdata*?
local Win32Window = {}
Win32Window.__index = Win32Window

---@param eventLoop winit-win32.EventLoop
---@param width number
---@param height number
function Win32Window.new(eventLoop, width, height)
	-- We need to adjust the window size to account for borders and title bar
	-- This is specific to windows as the width and height when creating a window isn't just the client area.
	local rect = user32.Rect()
	rect.right = width
	rect.bottom = height

	if not user32.adjustWindowRect(rect, bit.bor(user32.WS.VISIBLE, user32.WS.OVERLAPPEDWINDOW), false) then
		error("Failed to adjust window rect: " .. kernel32.getLastErrorMessage())
	end

	local adjustedWidth = rect.right - rect.left
	local adjustedHeight = rect.bottom - rect.top

	local window = user32.createWindow(
		0,
		eventLoop.class.lpszClassName,
		"Title",
		bit.bor(user32.WS.VISIBLE, user32.WS.OVERLAPPEDWINDOW),
		user32.CW_USEDEFAULT,
		user32.CW_USEDEFAULT,
		adjustedWidth,
		adjustedHeight,
		nil,
		nil,
		eventLoop.class.hInstance,
		nil
	)

	if window == nil then
		error("Failed to create window: " .. kernel32.getLastErrorMessage())
	end

	-- A window is a place files may be dropped on, which is said rather than assumed: until it
	-- is, the shell will not send a window the drops it is under.
	shell32.dragAcceptFiles(window, true)

	return setmetatable({ hwnd = window, id = ffiptrToDouble(window), width = width, height = height }, Win32Window)
end

local cursors = {
	pointer = user32.IDC.ARROW,
	hand2 = user32.IDC.HAND,
}

---@param shape "pointer" | "hand2"
function Win32Window:setCursor(shape)
	local idc = assert(cursors[shape], "Unknown cursor shape: " .. tostring(shape))
	local cursor = user32.loadCursor(nil, idc)
	user32.setCursor(cursor)
	self.currentCursor = cursor
end

function Win32Window:resetCursor()
	self:setCursor("pointer")
end

---@param title string
function Win32Window:setTitle(title)
	user32.setWindowText(self.hwnd, title)
end

function Win32Window:destroy()
	user32.destroyWindow(self.hwnd)
end

---@class winit-win32.EventLoop: winit.EventLoop
---@field windows table<string, winit-win32.Window>
---@field class winapi.user32.ffi.WNDCLASSEXA
---@field isActive boolean
---@field currentMode "poll" | "wait"
---@field handler winit.EventManager
---@field callback winit.EventHandler
local Win32EventLoop = {}
Win32EventLoop.__index = Win32EventLoop

-- A window class belongs to the process rather than to the loop that made it, and the system
-- refuses a second one under a name already taken. What each loop registers is a name of its
-- own, so that making another one -- a second loop in the same program, or a suite that runs
-- several of them -- is always possible: what a class carries is the window procedure its
-- windows are dispatched to, and that is the loop's own.
local classCount = 0

local ERROR_CLASS_ALREADY_EXISTS = 1410

function Win32EventLoop.new()
	local hInstance = kernel32.getModuleHandle(nil)
	if hInstance == nil then
		error("Failed to get module handle: " .. kernel32.getLastErrorMessage())
	end

	local class = user32.WndClassEx()
	local self = setmetatable({ class = class, windows = {} }, Win32EventLoop)

	classCount = classCount + 1
	class.lpszClassName = "winit-window-" .. classCount
	class.lpfnWndProc = user32.WndProc(function(hwnd, msg, wParam, lParam)
		if not self.callback then
			return user32.defWindowProc(hwnd, msg, wParam, lParam)
		end

		local window = self.windows[tostring(ffiptrToDouble(hwnd))]
		if not window then
			return user32.defWindowProc(hwnd, msg, wParam, lParam)
		end

		if msg == user32.WM.PAINT then
			self.callback({ name = "redraw", window = window }, self.handler)
			return 0
		elseif msg == user32.WM.SIZE then
			if window then
				window.width = user32.LOWORD(lParam)
				window.height = user32.HIWORD(lParam)
			end

			self.callback({ name = "resize", window = window }, self.handler)
			return 0
		elseif msg == 0x0018 then -- WM_SHOWWINDOW
			if user32.LOWORD(wParam) ~= 0 then
				self.callback({ window = window, name = "map" }, self.handler)
			else
				self.callback({ window = window, name = "unmap" }, self.handler)
			end

			return 0
		elseif msg == user32.WM.MOUSEMOVE then
			local x = user32.GET_X_LPARAM(lParam)
			local y = user32.GET_Y_LPARAM(lParam)
			self.callback({ window = window, name = "mouseMove", x = x, y = y }, self.handler)
			return 0
		elseif msg == user32.WM.LBUTTONDOWN then
			local x = user32.GET_X_LPARAM(lParam)
			local y = user32.GET_Y_LPARAM(lParam)
			self.callback({ window = window, name = "mousePress", x = x, y = y }, self.handler)
			return 0
		elseif msg == user32.WM.LBUTTONUP then
			local x = user32.GET_X_LPARAM(lParam)
			local y = user32.GET_Y_LPARAM(lParam)
			self.callback({ window = window, name = "mouseRelease", x = x, y = y }, self.handler)
			return 0
		elseif msg == user32.WM.CLOSE then
			self.callback({ window = window, name = "windowClose" }, self.handler)
			return 0
		elseif msg == user32.WM.DROPFILES then
			-- What a drag carried, which the shell hands over as one thing to read the files out
			-- of and be done with -- so what is passed on is the paths, and the drop itself is
			-- finished with inside the read.
			local paths, x, y = readDrop(ffi.cast("HDROP", wParam))
			self.callback({ window = window, name = "fileDrop", paths = paths, x = x, y = y }, self.handler)
			return 0
		end

		return user32.defWindowProc(hwnd, msg, wParam, lParam)
	end)
	class.hCursor = user32.loadCursor(nil, user32.IDC.ARROW)
	class.hIcon = user32.loadIcon(nil, user32.IDI.APPLICATION)
	class.hbrBackground = user32.getSysColorBrush(user32.COLOR.WINDOW)
	class.style = bit.bor(user32.CS.HREDRAW, user32.CS.VREDRAW)

	class.hInstance = hInstance

	-- The names already taken are stepped past rather than counted from this state's own
	-- beginning: a class belongs to the process, and a second Lua state -- which is what every
	-- test file of a suite is -- starts counting again from nothing.
	local registered = false
	for step = 0, 64 do
		class.lpszClassName = ("winit-window-%d"):format(classCount + step)

		if user32.registerClass(class) ~= 0 then
			classCount = classCount + step + 1
			registered = true
			break
		end

		if kernel32.getLastError() ~= ERROR_CLASS_ALREADY_EXISTS then
			break
		end
	end

	if not registered then
		error("Failed to register window class: " .. kernel32.getLastErrorMessage())
	end

	local handler = {}
	do
		function handler.exit(_)
			self.isActive = false
		end

		function handler.setMode(_, mode)
			self.currentMode = mode
		end

		--- A wait with a deadline is not in this backend: a screen with something to do on its own
		--- is woken by the events it is given and no earlier.
		---@param seconds number?
		function handler.setTimeout(_, seconds) end

		function handler.requestRedraw(_, window)
			window.shouldRedraw = true
		end

		function handler.close(_, window)
			self:close(window)
		end
	end

	self.handler = handler

	return self
end

---@param window winit-win32.Window
function Win32EventLoop:register(window)
	-- A window is looked up by what the platform calls it, which on this one is the handle as
	-- a number: what the loop keeps them under is the same thing the X11 backend keeps them
	-- under -- a string -- so that a program reading `windows` sees one shape either way.
	self.windows[tostring(window.id)] = window
end

---@param window winit-win32.Window
function Win32EventLoop:close(window)
	window:destroy()
	self.windows[tostring(window.id)] = nil
end

---@param callback winit.EventHandler
function Win32EventLoop:run(callback)
	self.isActive = true
	self.currentMode = "poll"
	self.callback = function(event, handler)
		local ok, err = xpcall(callback, debug.traceback, event, handler)
		if not ok then
			print("Error in event loop callback: " .. tostring(err))
			os.exit(1)
		end
	end

	for _, window in pairs(self.windows) do
		self.callback({ name = "create", window = window }, self.handler)
	end

	local msg = user32.Msg()
	while self.isActive do
		if self.currentMode == "poll" then
			if user32.peekMessage(msg, nil, 0, 0, user32.PM.REMOVE) then
				user32.translateMessage(msg)
				user32.dispatchMessage(msg)
			end
		else
			user32.getMessage(msg, nil, 0, 0)
			user32.translateMessage(msg)
			user32.dispatchMessage(msg)
		end

		for _, window in pairs(self.windows) do
			if window.shouldRedraw then
				window.shouldRedraw = false
				callback({ name = "redraw", window = window }, self.handler)
			end
		end

		callback({ name = "aboutToWait" }, self.handler)
	end

	for _, window in pairs(self.windows) do
		self:close(window)
	end
end

---@param hInstance ffi.cdata*
function Win32EventLoop:cleanup(hInstance)
	user32.unregisterClass(self.class.lpszClassName, hInstance)
end

return { Window = Win32Window, EventLoop = Win32EventLoop, Clipboard = Clipboard }
