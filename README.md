# winit [![Tests](https://github.com/bycruz/winit/actions/workflows/test.yml/badge.svg)](https://github.com/bycruz/winit/actions/workflows/test.yml)

Window creation and handling library in pure LuaJIT.

## Support

| Arch   | Windows | Linux | macOS |
| ------ | ------- | ----- | ----- |
| x86-64 | ✅      | ✅    | ❌    |

## Installation

Use this package with the [lde](https://lde.sh/) package manager.

```bash
lde add winit
```

## Backends

The backends are packages of their own, and a program installs the one its platform runs on:

| Package       | Platform | Built on        |
| ------------- | -------- | --------------- |
| `winit-x11`   | Linux    | Xlib and XInput2, through [x11api](https://github.com/bycruz/x11api) |
| `winit-win32` | Windows  | user32 and shell32, through [winapi](https://github.com/bycruz/winapi) |

`linux` and `windows` are features lde turns on by itself, so naming winit is enough to get the
right one:

```jsonc
"dependencies": {
	"winit": { "version": "0.2" }
}
```

The backend a program does not run on is not installed at all, which is what keeps it out of a
bundle: a whole platform's worth of code that could never run there.

## Windows

```lua
local winit = require("winit")

local eventLoop = winit.EventLoop.new()
local window = winit.Window.fromEventLoop(eventLoop)
window:setTitle("my window")

eventLoop:run(function(event, handler)
	if event.name == "windowClose" then
		handler:exit()
	elseif event.name == "keyPress" and event.key == "escape" then
		handler:exit()
	elseif event.name == "fileDrop" then
		for _, path in ipairs(event.paths) do
			print("dropped: " .. path)
		end
	end
end)
```

## Clipboard

A clipboard is the system's rather than a window's, so a program wants one of them, not one per
window. Text is what both platforms agree on:

```lua
local clipboard = winit.Clipboard.new(eventLoop)

clipboard:setText("what a copy would put there")  -- offered to the rest of the system
clipboard:getText()                                -- what is on it now, or nil
clipboard:clear()                                  -- emptied
```

On Linux a clipboard is a conversation: what a program offers is served while it runs, and what
it reads is asked of whichever program is offering it. A read waits for that program to answer,
up to a second, and events that arrive while it waits are handed to the event loop afterwards
rather than lost.

## Files

Files dropped on a window arrive as a path list, one event for the whole drop:

```lua
---@type winit.Event
{ window = window, name = "fileDrop", paths = { "/home/user/notes.txt" }, x = 120, y = 80 }
```

Linux uses XDND, the X drag and drop protocol, so a window says it accepts files before anything
is dragged onto it; Windows uses the shell's own drop messages.

## Examples

Each example is a package of its own, run from its directory with `lde run`:

```bash
cd examples/clipboard && lde run
```
