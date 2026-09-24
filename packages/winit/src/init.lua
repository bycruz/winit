local ffi = require("ffi")

--- The package each platform's backend lives in. Both are named after the platform features
--- lde turns on by itself, so depending on winit is enough to get one: a program that runs on
--- linux installs winit-x11 and never winit-win32, and the other way round. The backend a
--- program does not run on is not installed at all, which is what keeps it out of a bundle --
--- a whole platform's worth of code that could never run there.
---@type table<string, string>
local BACKENDS = {
	Windows = "winit-win32",
	Linux = "winit-x11",
}

local backendPackage = BACKENDS[ffi.os]
if not backendPackage then
	error("Unsupported platform: " .. ffi.os)
end

-- NOTE: This dynamically requires the backend specific module to avoid loading unnecessary code
local ok, backend = pcall(require, backendPackage)
if not ok then
	error("winit was installed without its " .. ffi.os .. " backend (" .. backendPackage
		.. "): " .. tostring(backend))
end

---@alias winit.CursorGrab "locked" | "contain" | "none"

---@class winit.Window
---@field id any?
---@field width number
---@field height number
---@field shouldRedraw boolean
---@field frameAsked boolean? # The window manager asked for a frame, and waits to be told it is ready
---@field new fun(eventLoop: winit.EventLoop, width: number, height: number): winit.Window
---@field destroy fun(self: winit.Window)
---@field setTitle fun(self: winit.Window, title: string)
---@field setCursor fun(self: winit.Window, shape: string)
---@field resetCursor fun(self: winit.Window)
---@field setCursorGrab fun(self: winit.Window, mode: winit.CursorGrab)
local Window = backend.Window

---@param eventLoop winit.EventLoop
function Window.fromEventLoop(eventLoop) ---@return winit.Window
	local window = Window.new(eventLoop, 1200, 720)
	eventLoop:register(window)
	return window
end

---@alias winit.KeyModifiers { shift: boolean, lock: boolean, ctrl: boolean, alt: boolean, super: boolean }

---@alias winit.KeyName
--- | "space" | "backspace" | "tab" | "return" | "escape"
--- | "home" | "end" | "insert" | "delete" | "page-up" | "page-down"
--- | "left" | "right" | "up" | "down"
--- | "f1" | "f2" | "f3" | "f4" | "f5" | "f6" | "f7" | "f8" | "f9" | "f10" | "f11" | "f12"
--- | "left-shift" | "right-shift" | "left-ctrl" | "right-ctrl"
--- | "left-alt" | "right-alt" | "left-super" | "right-super" | "caps-lock"
--- | string

---@alias winit.Event
--- | { name: "aboutToWait" }
--- | { window: winit.Window, name: "windowClose" }
--- | { window: winit.Window, name: "redraw" }
--- | { window: winit.Window, name: "resize" }
--- | { window: winit.Window, name: "map" }
--- | { window: winit.Window, name: "create" }
--- | { window: winit.Window, name: "unmap" }
--- | { window: winit.Window, name: "mouseMove", x: number, y: number }
--- | { name: "mouseMotion", dx: number, dy: number }
--- | { window: winit.Window, name: "mouseScroll", dx: number, dy: number }
--- | { window: winit.Window, name: "mousePress", x: number, y: number, button: number }
--- | { window: winit.Window, name: "mouseRelease", x: number, y: number, button: number }
--- | { window: winit.Window, name: "keyPress", key: winit.KeyName, modifiers: winit.KeyModifiers, text: string?, repeated: boolean? }
--- | { window: winit.Window, name: "keyRelease", key: winit.KeyName, modifiers: winit.KeyModifiers, repeated: boolean? }
--- | { window: winit.Window, name: "focusIn" }
--- | { window: winit.Window, name: "focusOut" }
--- | { window: winit.Window, name: "fileDrop", paths: string[], x: number, y: number }

--- A window's clipboard: what a program copies to and pastes from. A platform hands its
--- clipboard around as a whole, so what this is a handle on is the system's, not a window's --
--- one of these is what a program wants, and a paste lands wherever the program puts it.
---
--- Text is what both platforms agree on, and what a program reading what a player pasted
--- needs; anything else is a format the two do not name the same way.
---@class winit.Clipboard
---@field new fun(eventLoop: winit.EventLoop): winit.Clipboard
---@field setText fun(self: winit.Clipboard, text: string) # Offer this text to the rest of the system
---@field getText fun(self: winit.Clipboard): string? # What the clipboard holds, or nothing when it holds no text
---@field clear fun(self: winit.Clipboard) # Empty the clipboard
local Clipboard = backend.Clipboard

---@alias winit.EventLoopMode "poll" | "wait"

---@class winit.EventManager
---@field exit fun(self)
---@field close fun(self, window: winit.Window)
---@field requestRedraw fun(self, window: winit.Window)
---@field setMode fun(self, mode: winit.EventLoopMode)
---@field setTimeout fun(self, seconds: number?) # How long the next wait may last, or nothing to wait out an event

---@alias winit.EventHandler fun(event: winit.Event, handler: winit.EventManager)

---@class winit.EventLoop
---@field windows table<string, winit.Window>
---@field new fun(): winit.EventLoop
---@field register fun(self: winit.EventLoop, window: winit.Window)
---@field close fun(self: winit.EventLoop, window: winit.Window)
---@field run fun(self: winit.EventLoop, callback: winit.EventHandler)
local EventLoop = backend.EventLoop

return {
	EventLoop = EventLoop,
	Window = Window,
	Clipboard = Clipboard,
}
