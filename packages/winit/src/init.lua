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
	OSX = "winit-macos",
}

local backendPackage = BACKENDS[ffi.os]
if not backendPackage then
	error("Unsupported platform: " .. ffi.os)
end

-- NOTE: This dynamically requires the backend specific module to avoid loading unnecessary code
local ok, backend = pcall(require, backendPackage)
---@class winit.Backend
---@field Window winit.Window
---@field EventLoop winit.EventLoop
---@field Clipboard winit.Clipboard
---@field FileDialog winit.FileDialog?
if not ok then
	error("winit was installed without its " .. ffi.os .. " backend (" .. backendPackage
		.. "): " .. tostring(backend))
end

local backendApi = backend --[[@as winit.Backend]]

---@alias winit.CursorGrab "locked" | "contain" | "none"

--- The picture a tray icon is drawn from: straight RGBA, four bytes a pixel, as an image decodes
--- to. The backend scales it to the size the shell has room for, which is the system's small icon
--- at the display's scale.
---@class winit.TrayIcon
---@field width number
---@field height number
---@field rgba string

--- One line of a tray menu: a choice, or a rule between choices. A choice is what the app is told
--- about when it is picked, by the id it was given; a separator is `{ separator = true }` and
--- nothing else, so its id and label are absent.
---@class winit.TrayItem
---@field id string? # What the app is told back when this line is picked
---@field label string? # What the line says
---@field checked boolean? # Drawn with its tick, where the choice is one of a set
---@field disabled boolean? # Shown and refused
---@field default boolean? # The one the menu opens on, and the one an activated icon picks
---@field separator boolean? # A rule rather than a choice

--- What a window's icon in the notification area shows and offers: a picture, what the pointer over
--- it says, and the menu a right click or the keyboard's context key opens.
---@class winit.Tray
---@field icon winit.TrayIcon
---@field tooltip string? # What the pointer over the icon says; the backend cuts it to what the shell allows
---@field menu winit.TrayItem[]? # The choices offered, in the order they are drawn

---@class winit.Window
---@field id any?
---@field width number
---@field height number
---@field shouldRedraw boolean
---@field frameAsked boolean? # The window manager asked for a frame, and waits to be told it is ready
---@field visible boolean? # Whether the window is on the screen: false while it is hidden or minimized, nothing where the backend keeps no track of it
---@field hide (fun(self: winit.Window))? # Take the window off the screen and off the taskbar, its loop and its media keys still working
---@field show (fun(self: winit.Window))? # Bring a hidden or minimized window back, restored, in front and with the keyboard
---@field setTray (fun(self: winit.Window, tray: winit.Tray): boolean)? # Put or update this window's icon in the notification area; false where the shell refused it
---@field removeTray (fun(self: winit.Window))? # Take the icon out of the notification area; destroying the window does too
---@field new fun(eventLoop: winit.EventLoop, width: number, height: number): winit.Window
---@field fromEventLoop fun(eventLoop: winit.EventLoop): winit.Window
---@field destroy fun(self: winit.Window)
---@field setTitle fun(self: winit.Window, title: string)
---@field setCursor fun(self: winit.Window, shape: string)
---@field resetCursor fun(self: winit.Window)
---@field setCursorGrab fun(self: winit.Window, mode: winit.CursorGrab)
---@field setIcon (fun(self: winit.Window, width: number, height: number, rgba: string))? # A square picture for the title bar, where the backend has one
---@field captureMediaKeys (fun(self: winit.Window): string[])? # Takes the play, stop, next and previous keys whether or not the window has focus, where the backend can; returns the ones another program already holds
---@field releaseMediaKeys (fun(self: winit.Window))? # Gives back what captureMediaKeys took; destroying the window does too
local Window = backendApi.Window

---@param eventLoop winit.EventLoop
function Window.fromEventLoop(eventLoop) ---@return winit.Window
	local window = Window.new(eventLoop, 1200, 720)
	eventLoop:register(window)
	return window
end

--- A media key or a media button: on a keyboard, a headset or a remote, or a mouse button set to one.
---@alias winit.MediaAction "playPause" | "play" | "pause" | "stop" | "next" | "previous"

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
--- | { window: winit.Window, name: "minimize" }
--- | { window: winit.Window, name: "restore" }
--- | { window: winit.Window, name: "trayClick" }
--- | { window: winit.Window, name: "trayMenu", id: string }
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
--- | { window: winit.Window, name: "mediaKey", action: winit.MediaAction }

--- A window's clipboard: what a program copies to and pastes from. A platform hands its
--- clipboard around as a whole, so what this is a handle on is the system's, not a window's --
--- one of these is what a program wants, and a paste lands wherever the program puts it.
---
--- Text is what both platforms agree on, and what a program reading what a player pasted
--- needs; anything else is a format the two do not name the same way.
---@class winit.Clipboard
---@field new fun(eventLoop: winit.EventLoop?): winit.Clipboard
---@field setText fun(self: winit.Clipboard, text: string) # Offer this text to the rest of the system
---@field getText fun(self: winit.Clipboard): string? # What the clipboard holds, or nothing when it holds no text
---@field clear fun(self: winit.Clipboard) # Empty the clipboard
local Clipboard = backendApi.Clipboard

--- One filter in a file dialog: a name and the extensions it accepts.
---@class winit.FileFilter
---@field name string
---@field extensions string[]

--- What a file dialog is asked for.
---@class winit.FileDialog.OpenOptions
---@field title string?
---@field directory boolean? # Choose folders rather than files
---@field multiple boolean? # Allow more than one answer
---@field filters winit.FileFilter[]? # File filters offered by the dialog

--- A system dialog of the platform's own. The call is modal: it returns when the dialog is closed,
--- with the chosen paths, empty when it was cancelled.
---@class winit.FileDialog
---@field open fun(window: winit.Window?, opts: winit.FileDialog.OpenOptions?): string[]
---@field pickFolder fun(window: winit.Window?, opts: { title: string? }?): string?
---@field pickFile fun(window: winit.Window?, opts: { title: string?, filters: winit.FileFilter[]? }?): string?
---@field pickFiles fun(window: winit.Window?, opts: { title: string?, filters: winit.FileFilter[]? }?): string[]
local FileDialog = nil

if backendApi.FileDialog ~= nil then
	local backend = backendApi.FileDialog

	FileDialog = {}

	---@param window winit.Window?
	---@param opts winit.FileDialog.OpenOptions?
	---@return string[]
	function FileDialog.open(window, opts)
		return backend.open(window, opts) or {}
	end

	---@param window winit.Window?
	---@param opts { title: string? }?
	---@return string?
	function FileDialog.pickFolder(window, opts)
		local paths = backend.open(window, {
			title = opts ~= nil and opts.title or nil,
			directory = true,
			multiple = false,
		})

		return paths ~= nil and paths[1] or nil
	end

	---@param window winit.Window?
	---@param opts { title: string?, filters: winit.FileFilter[]? }?
	---@return string?
	function FileDialog.pickFile(window, opts)
		local paths = backend.open(window, {
			title = opts ~= nil and opts.title or nil,
			filters = opts ~= nil and opts.filters or nil,
		})

		return paths ~= nil and paths[1] or nil
	end

	---@param window winit.Window?
	---@param opts { title: string?, filters: winit.FileFilter[]? }?
	---@return string[]
	function FileDialog.pickFiles(window, opts)
		return backend.open(window, {
			title = opts ~= nil and opts.title or nil,
			filters = opts ~= nil and opts.filters or nil,
			multiple = true,
		}) or {}
	end
end

---@alias winit.EventLoopMode "poll" | "wait"

--- What a program does to the loop it runs in: end it, close a window, ask for a frame, and choose
--- how the loop waits, and how long for.
---
--- `setTimeout` is the only timer the loop has. A program with something to do on its own -- a
--- caret to blink, a key repeating, a frame the display's clock has not come to yet -- says how
--- long from now it wants the loop back, and is asked again at every `aboutToWait`; the loop waits
--- for an event or for that deadline, whichever comes first, and a deadline is a wait's whole
--- length at most. `nil` is a wait with no end to it, which is what a program with nothing to do
--- on its own asks for.
---@class winit.EventManager
---@field exit fun(self: winit.EventManager)
---@field close fun(self: winit.EventManager, window: winit.Window)
---@field requestRedraw fun(self: winit.EventManager, window: winit.Window)
---@field setMode fun(self: winit.EventManager, mode: winit.EventLoopMode)
---@field setTimeout fun(self: winit.EventManager, seconds: number?) # How long the next wait may last, in seconds, or nothing to wait out an event

---@alias winit.EventHandler fun(event: winit.Event, handler: winit.EventManager)

---@class winit.EventLoop
---@field windows table<string, winit.Window>
---@field new fun(): winit.EventLoop
---@field register fun(self: winit.EventLoop, window: winit.Window)
---@field close fun(self: winit.EventLoop, window: winit.Window)
---@field run fun(self: winit.EventLoop, callback: winit.EventHandler)
local EventLoop = backendApi.EventLoop

return {
	EventLoop = EventLoop,
	Window = Window,
	Clipboard = Clipboard,
	FileDialog = FileDialog,
}
