local ffi = require("ffi")

local windowBackend =
	ffi.os == "Windows" and require("winit.raw.win32")
	or ffi.os == "Linux" and require("winit.raw.x11")
	or error("Unsupported platform: " .. ffi.os)

---@alias winit.CursorGrab "locked" | "contain" | "none"

---@class winit.Window
---@field id any?
---@field width number
---@field height number
---@field shouldRedraw boolean
---@field new fun(eventLoop: winit.EventLoop, width: number, height: number): winit.Window
---@field destroy fun(self: winit.Window)
---@field setTitle fun(self: winit.Window, title: string)
---@field setCursor fun(self: winit.Window, shape: string)
---@field resetCursor fun(self: winit.Window)
---@field setCursorGrab fun(self: winit.Window, mode: winit.CursorGrab)
local Window = windowBackend.Window

---@param eventLoop winit.EventLoop
function Window.fromEventLoop(eventLoop) ---@return winit.Window
	local window = Window.new(eventLoop, 1200, 720)
	eventLoop:register(window)
	return window
end

---@alias winit.KeyModifiers { shift: boolean, lock: boolean, ctrl: boolean, alt: boolean, super: boolean }

---@alias winit.KeyName
--- | "backspace" | "tab" | "return" | "escape"
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
--- | { window: winit.Window, name: "keyPress", key: winit.KeyName, modifiers: winit.KeyModifiers }
--- | { window: winit.Window, name: "keyRelease", key: winit.KeyName, modifiers: winit.KeyModifiers }
--- | { window: winit.Window, name: "focusIn" }
--- | { window: winit.Window, name: "focusOut" }

---@alias winit.EventLoopMode "poll" | "wait"

---@class winit.EventManager
---@field exit fun(self)
---@field close fun(self, window: winit.Window)
---@field requestRedraw fun(self, window: winit.Window)
---@field setMode fun(self, mode: winit.EventLoopMode)

---@alias winit.EventHandler fun(event: winit.Event, handler: winit.EventManager)

---@class winit.EventLoop
---@field windows table<string, winit.Window>
---@field new fun(): winit.EventLoop
---@field register fun(self: winit.EventLoop, window: winit.Window)
---@field close fun(self: winit.EventLoop, window: winit.Window)
---@field run fun(self: winit.EventLoop, callback: winit.EventHandler)
local EventLoop = windowBackend.EventLoop

return {
	EventLoop = EventLoop,
	Window = Window,
}
