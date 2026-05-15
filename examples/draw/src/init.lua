-- An animated HSV rainbow gradient drawn entirely with CPU rendering
-- (GDI on Windows, Xlib on X11). The gradient scrolls horizontally,
-- cycling through hues continuously.
--
-- Close the window or press Escape to exit.

local ffi = require("ffi")
local winit = require("winit")

local eventLoop = winit.EventLoop.new()
local window = winit.Window.fromEventLoop(eventLoop)
window:setTitle("cpu gradient - esc to exit")

-- HSV -> RGB

---@param h number  hue        0-360
---@param s number  saturation 0-1
---@param v number  value      0-1
---@return number r, number g, number b  (each 0-255)
local function hsvToRgb(h, s, v)
	local c = v * s
	local hp = h / 60
	local x = c * (1 - math.abs(hp % 2 - 1))
	local m = v - c

	local r1, g1, b1
	if hp < 1 then
		r1, g1, b1 = c, x, 0
	elseif hp < 2 then
		r1, g1, b1 = x, c, 0
	elseif hp < 3 then
		r1, g1, b1 = 0, c, x
	elseif hp < 4 then
		r1, g1, b1 = 0, x, c
	elseif hp < 5 then
		r1, g1, b1 = x, 0, c
	else
		r1, g1, b1 = c, 0, x
	end

	return math.floor((r1 + m) * 255 + 0.5),
		math.floor((g1 + m) * 255 + 0.5),
		math.floor((b1 + m) * 255 + 0.5)
end

-- platform-specific drawing helpers

local drawGradient

if ffi.os == "Windows" then
	local gdi = require("winapi.gdi")

	local function fillStrip(hdc, x, y, w, h, r, g, b)
		local colorRef = bit.bor(r, bit.lshift(g, 8), bit.lshift(b, 16))
		local brush = gdi.createSolidBrush(colorRef)
		local rect = gdi.Rect()
		rect.left = x
		rect.top = y
		rect.right = x + w
		rect.bottom = y + h
		gdi.fillRect(hdc, rect, brush)
		gdi.deleteObject(brush)
	end

	---@param hwnd userdata
	---@param w number  client width
	---@param h number  client height
	---@param hue number  hue offset (degrees)
	drawGradient = function(hwnd, w, h, hue)
		if w == 0 or h == 0 then return end

		local ps = gdi.PaintStruct()
		local hdc = gdi.beginPaint(hwnd, ps)
		if hdc == nil then return end

		local nStrips = math.max(1, math.min(w, 256))
		local stripW = w / nStrips

		for i = 0, nStrips - 1 do
			local hx = (i / nStrips) * 360 + hue
			local r, g, b = hsvToRgb(hx, 1, 1)
			local x = math.floor(i * stripW + 0.5)
			local sw = math.floor((i + 1) * stripW + 0.5) - x
			if sw > 0 then
				fillStrip(hdc, x, 0, sw, h, r, g, b)
			end
		end

		gdi.endPaint(hwnd, ps)
	end
elseif ffi.os == "Linux" then
	local x11 = require("x11api")

	---@param display userdata
	---@param win number   X11 Window ID
	---@param w number   client width
	---@param h number   client height
	---@param hue number   hue offset (degrees)
	drawGradient = function(display, win, w, h, hue)
		if w == 0 or h == 0 then return end

		local gc = x11.createGC(display, win, 0, nil)
		if gc == nil then return end

		local nStrips = math.max(1, math.min(w, 256))
		local stripW = w / nStrips

		for i = 0, nStrips - 1 do
			local hx = (i / nStrips) * 360 + hue
			local r, g, b = hsvToRgb(hx, 1, 1)
			local pixel = bit.bor(bit.lshift(r, 16), bit.lshift(g, 8), b)
			x11.setForeground(display, gc, pixel)

			local x = math.floor(i * stripW + 0.5)
			local sw = math.floor((i + 1) * stripW + 0.5) - x
			if sw > 0 then
				x11.fillRectangle(display, win, gc, x, 0, sw, h)
			end
		end

		x11.freeGC(display, gc)
		x11.flush(display)
	end
else
	error("Unsupported platform: " .. ffi.os)
end

-- draw helper

local time = 0

local function fillWindow()
	time = time + 1
	local hue = (time * 2) % 360

	if ffi.os == "Windows" then
		---@diagnostic disable-next-line: undefined-field
		drawGradient(window.hwnd, window.width, window.height, hue)
	else
		---@diagnostic disable-next-line: undefined-field
		drawGradient(window.display, window.id, window.width, window.height, hue)
	end
end

-- event loop

eventLoop:run(function(event, handler)
	if event.name == "windowClose" then
		handler:exit()
	elseif event.name == "keyPress" and event.key == "escape" then
		handler:exit()
	elseif event.name == "create" then
		fillWindow()
	elseif event.name == "redraw" then
		fillWindow()
	elseif event.name == "resize" then
		handler:requestRedraw(window)
	elseif event.name == "aboutToWait" then
		handler:requestRedraw(window)
	end
end)
