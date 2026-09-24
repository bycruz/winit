-- What a program does with the clipboard and with a drop: ctrl+c offers a line of text to the
-- rest of the system, ctrl+v reads back whatever is on it, and a file dragged onto the window is
-- reported with the paths it was dropped from.
--
-- Nothing here names a platform: the clipboard and the drop are winit's, and which system is
-- under them is the platform's own business.
--
-- Close the window or press Escape to exit.

local winit = require("winit")

local eventLoop = winit.EventLoop.new()
local window = winit.Window.fromEventLoop(eventLoop)
window:setTitle("winit clipboard - ctrl+c copies, ctrl+v pastes, drop a file here")

-- A clipboard is the system's rather than a window's: what a program holds is a handle on the
-- one clipboard there is, and a paste lands wherever the program puts it.
local clipboard = winit.Clipboard.new(eventLoop)

eventLoop:run(function(event, handler)
	if event.name == "windowClose" then
		handler:exit()
	elseif event.name == "keyPress" then
		if event.key == "escape" then
			handler:exit()
		elseif event.key == "c" and event.modifiers.ctrl then
			clipboard:setText("copied by winit")
			print("copied: copied by winit")
		elseif event.key == "v" and event.modifiers.ctrl then
			print("pasted: " .. tostring(clipboard:getText()))
		end
	elseif event.name == "fileDrop" then
		-- Where the drop was let go of is the window's own corner, the same one a pointer's
		-- position comes back in.
		print(("%d file(s) dropped at %d,%d"):format(#event.paths, event.x, event.y))

		for _, path in ipairs(event.paths) do
			print("  " .. path)
		end
	end
end)
