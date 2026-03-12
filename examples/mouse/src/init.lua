local winit = require("winit")

local eventLoop = winit.EventLoop.new()
local window = winit.Window.fromEventLoop(eventLoop)
window:setTitle("mouse demo — click to lock")

local escaped = false

local function lock()
	escaped = false
	window:setCursorGrab("locked")
	window:setTitle("mouse demo — locked (esc to release)")
end

local function unlock()
	escaped = true
	window:setCursorGrab("none")
	window:setTitle("mouse demo — click to lock")
end

eventLoop:run(function(event, handler)
	if event.name == "windowClose" then
		handler:exit()
	elseif event.name == "focusIn" then
		if not escaped then lock() end
	elseif event.name == "focusOut" then
		if not escaped then
			window:setCursorGrab("none")
		end
	elseif event.name == "keyPress" and event.key == "escape" then
		unlock()
	elseif event.name == "mousePress" then
		if escaped then lock() end
	elseif event.name == "mouseMotion" then
		print(string.format("dx=%.2f  dy=%.2f", event.dx, event.dy))
	end
end)
