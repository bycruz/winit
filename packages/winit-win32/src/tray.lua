-- The notification area: the small icon a program puts beside the clock, and the menu it opens.
--
-- The shell owns both. It draws the icon and shows the menu, so what this module does is hand it a
-- picture and a list of choices, and turn what it says back into the events the loop carries. An
-- icon belongs to one window -- the window is its owner -- and every message the shell sends about
-- it comes to that window, which is how an event ends up carrying the window it is about.
local ffi = require("ffi")
local kernel32 = require("winapi.kernel32")
local user32 = require("winapi.user32")

-- The calls the shell's icon and menus are made through, declared under names of winit's own: a C
-- function has one declaration in a process, and another library declaring one of these with a
-- signature of its own would refuse every call through it. See `winit-win32.dialog`, which binds
-- the COM entry points the same way.
--
-- The structs are spelled as shellapi.h spells them rather than with the names of the system's
-- headers, so that a program declaring one of those for itself does not collide with this. The
-- layout has to be the one the shell knows: `NOTIFYICONDATAW` is 976 bytes from Vista on, and the
-- balloon fields the icon does not use are there to make it that size.
ffi.cdef [[
	typedef struct {
		int fIcon;
		unsigned long xHotspot;
		unsigned long yHotspot;
		void *hbmMask;
		void *hbmColor;
	} WINIT_ICONINFO;

	typedef struct {
		unsigned long biSize;
		long biWidth;
		long biHeight;
		unsigned short biPlanes;
		unsigned short biBitCount;
		unsigned long biCompression;
		unsigned long biSizeImage;
		long biXPelsPerMeter;
		long biYPelsPerMeter;
		unsigned long biClrUsed;
		unsigned long biClrImportant;
	} WINIT_BITMAPINFOHEADER;

	typedef struct {
		unsigned long cbSize;
		void *hWnd;
		unsigned int uID;
		unsigned int uFlags;
		unsigned int uCallbackMessage;
		void *hIcon;
		unsigned short szTip[128];
		unsigned long dwState;
		unsigned long dwStateMask;
		unsigned short szInfo[256];
		unsigned int uVersion;
		unsigned short szInfoTitle[64];
		unsigned long dwInfoFlags;
		uint8_t guidItem[16];
		void *hBalloonIcon;
	} WINIT_NOTIFYICONDATAW;

	int winit_Shell_NotifyIconW(unsigned long message, const WINIT_NOTIFYICONDATAW *data)
		__asm__("Shell_NotifyIconW");
	unsigned int winit_RegisterWindowMessageW(const unsigned short *name)
		__asm__("RegisterWindowMessageW");

	void *winit_CreatePopupMenu(void) __asm__("CreatePopupMenu");
	int winit_AppendMenuW(void *menu, unsigned int flags, uintptr_t id,
		const unsigned short *text) __asm__("AppendMenuW");
	int winit_SetMenuDefaultItem(void *menu, unsigned int item, unsigned int byPosition)
		__asm__("SetMenuDefaultItem");
	unsigned long winit_TrackPopupMenuEx(void *menu, unsigned int flags, int x, int y, void *hwnd,
		const void *params) __asm__("TrackPopupMenuEx");
	int winit_DestroyMenu(void *menu) __asm__("DestroyMenu");
	int winit_SetForegroundWindow(void *hwnd) __asm__("SetForegroundWindow");
	int winit_PostMessageW(void *hwnd, unsigned int msg, uintptr_t wParam, intptr_t lParam)
		__asm__("PostMessageW");

	void *winit_CreateIconIndirect(const WINIT_ICONINFO *info) __asm__("CreateIconIndirect");
	int winit_DestroyIcon(void *icon) __asm__("DestroyIcon");
	void *winit_CreateBitmap(int width, int height, unsigned int planes, unsigned int bits,
		const void *data) __asm__("CreateBitmap");
	int winit_DeleteObject(void *object) __asm__("DeleteObject");
	void *winit_CreateDIBSection(void *hdc, const WINIT_BITMAPINFOHEADER *info, unsigned int usage,
		void **bits, void *section, unsigned long offset) __asm__("CreateDIBSection");
	int winit_GetSystemMetrics(int index) __asm__("GetSystemMetrics");
]]

-- Held rather than loaded where they are called: a library handle the collector lets go of unloads
-- the dll behind it, and what this module holds of it then points into nothing.
local user32Library = ffi.load("user32")
local shell32Library = ffi.load("shell32")
local gdi32Library = ffi.load("gdi32")

---@class winit-win32.TrayState
---@field added boolean # Whether the shell is holding the icon at all
---@field hIcon ffi.cdata*? # The picture the shell is drawing, as an icon handle
---@field iconWidth number? # What that picture was made from, which is how a new one is told from the same one
---@field iconHeight number?
---@field iconRgba string?
---@field tooltip string? # What the pointer over the icon says
---@field menu winit.TrayItem[]? # What a right click offers

local Tray = {}

--- The message the shell calls the icon's owner back on. It belongs to winit rather than to the
--- program: the window procedure is this backend's, and this is the only thing posting to it.
Tray.MESSAGE = 0x8001 -- WM_APP + 1

-- What one icon is known by on its window. A window has one icon, so the id is the same for all.
local TRAY_ID = 1

local NIM_ADD = 0
local NIM_MODIFY = 1
local NIM_DELETE = 2

local NIF_MESSAGE = 0x01
local NIF_ICON = 0x02
local NIF_TIP = 0x04

local MF_SEPARATOR = 0x0800
local MF_STRING = 0x0000
local MF_CHECKED = 0x0008
local MF_GRAYED = 0x0001
local MF_BYPOSITION = 0x0400

local TPM_RIGHTBUTTON = 0x0002
local TPM_NONOTIFY = 0x0080
local TPM_RETURNCMD = 0x0100

local WM_LBUTTONUP = 0x0202
local WM_RBUTTONUP = 0x0205
local WM_CONTEXTMENU = 0x007B
local WM_NULL = 0x0000

local SM_CXSMICON = 49
local SM_CYSMICON = 50

-- Where the shell names no size at all, which is nowhere it can be asked: the least an icon has
-- ever been drawn at.
local FALLBACK_ICON_SIZE = 16

-- What a tooltip holds, terminator included: the shell's own field, and what it cuts a longer one
-- to.
local TIP_UNITS = 128

--- A string as the shell wants it: UTF-16 in the field it goes in, cut to that field without
--- splitting a character in half. A high surrogate left without its low one is a question mark on
--- the screen, so the half of a pair that did not fit goes instead.
---@param field ffi.cdata* # the array of utf-16 code units to fill
---@param capacity number # how many code units it holds, terminator included
---@param text string
local function copyText(field, capacity, text)
	local wide = kernel32.utf8ToWide(text)
	if wide == nil then
		return
	end

	local at = 0
	while at < capacity - 1 and wide[at] ~= 0 do
		field[at] = wide[at]
		at = at + 1
	end

	if at > 0 and field[at - 1] >= 0xD800 and field[at - 1] <= 0xDBFF then
		at = at - 1
	end

	field[at] = 0
end

--- The size the shell draws an icon at: the system's small icon, which is the one beside the clock,
--- scaled with the display the way the process asked to be told about it.
---@return number width
---@return number height
local function iconSize()
	local width = tonumber(user32Library.winit_GetSystemMetrics(SM_CXSMICON))
	local height = tonumber(user32Library.winit_GetSystemMetrics(SM_CYSMICON))

	if width <= 0 or height <= 0 then
		return FALLBACK_ICON_SIZE, FALLBACK_ICON_SIZE
	end

	return width, height
end

--- The picture averaged to the size the shell has room for: each pixel of the result is the average
--- of the part of the picture it covers, weighted by how much of it that is.
---
--- Colour is averaged with its alpha already in it -- a pixel that is mostly transparent is mostly
--- the colour behind it rather than the colour it carries -- and comes out in that form, which is
--- what a window's icon wants: four bytes a pixel in the order a bitmap has them, top row first.
---@param icon winit.TrayIcon
---@param width number
---@param height number
---@return string pixels
local function scaledPixels(icon, width, height)
	local source = icon.rgba
	local sourceWidth, sourceHeight = icon.width, icon.height
	local byte = string.byte

	assert(#source == sourceWidth * sourceHeight * 4, "A tray icon's picture is not width * height pixels of RGBA")

	local out = {}
	local rowScale = sourceHeight / height
	local columnScale = sourceWidth / width

	for y = 0, height - 1 do
		local top = y * rowScale
		local bottom = top + rowScale
		local firstRow = math.floor(top)
		local lastRow = math.min(sourceHeight - 1, math.ceil(bottom) - 1)

		for x = 0, width - 1 do
			local left = x * columnScale
			local right = left + columnScale
			local firstColumn = math.floor(left)
			local lastColumn = math.min(sourceWidth - 1, math.ceil(right) - 1)
			local area, alpha, red, green, blue = 0, 0, 0, 0, 0

			for row = firstRow, lastRow do
				local weight = math.min(bottom, row + 1) - math.max(top, row)

				if weight > 0 then
					for column = firstColumn, lastColumn do
						local across = math.min(right, column + 1) - math.max(left, column)

						if across > 0 then
							local part = weight * across
							local at = (row * sourceWidth + column) * 4 + 1
							local a = byte(source, at + 3)

							area = area + part
							alpha = alpha + a * part
							red = red + byte(source, at) * a * part
							green = green + byte(source, at + 1) * a * part
							blue = blue + byte(source, at + 2) * a * part
						end
					end
				end
			end

			-- What is left of a colour once its alpha is in it: the average of the colour covered,
			-- weighted by the alpha that covers it, and on the same scale as the alpha itself.
			local scale = 255 * area
			out[#out + 1] = string.char(
				math.floor(blue / scale + 0.5),
				math.floor(green / scale + 0.5),
				math.floor(red / scale + 0.5),
				math.floor(alpha / area + 0.5)
			)
		end
	end

	return table.concat(out)
end

--- The icon the shell draws from a picture: a colour bitmap carrying its alpha, and the mask a
--- 32-bit icon still wants beside it -- an empty one, since where the icon is see-through is what
--- the alpha says, not the mask.
---@param width number
---@param height number
---@param pixels string # BGRA, top row first, as `scaledPixels` makes them
---@return ffi.cdata*? icon
local function makeIcon(width, height, pixels)
	local header = ffi.new("WINIT_BITMAPINFOHEADER", {
		biSize = ffi.sizeof("WINIT_BITMAPINFOHEADER"),
		biWidth = width,
		biHeight = -height, -- a negative height is a bitmap whose top row comes first
		biPlanes = 1,
		biBitCount = 32,
		biCompression = 0, -- BI_RGB
	})

	local bits = ffi.new("void *[1]")
	local color = gdi32Library.winit_CreateDIBSection(nil, header, 0, bits, nil, 0)

	if color == nil then
		return nil
	end

	ffi.copy(bits[0], pixels, width * height * 4)

	-- One bit a pixel, each row padded to a word, every bit set to nothing.
	local maskRow = math.floor((width + 15) / 16) * 2
	local maskBits = ffi.new("uint8_t[?]", maskRow * height)
	local mask = gdi32Library.winit_CreateBitmap(width, height, 1, 1, maskBits)

	if mask == nil then
		gdi32Library.winit_DeleteObject(color)
		return nil
	end

	local info = ffi.new("WINIT_ICONINFO", { fIcon = 1, hbmMask = mask, hbmColor = color })
	local icon = user32Library.winit_CreateIconIndirect(info)

	-- The icon keeps its own copy of both bitmaps, so these are done with either way.
	gdi32Library.winit_DeleteObject(color)
	gdi32Library.winit_DeleteObject(mask)

	return icon
end

--- One thing to tell the shell about the window's icon, with the picture and the tip it is to show.
---@param window winit-win32.Window
---@param message number # NIM_ADD, NIM_MODIFY or NIM_DELETE
---@param hIcon ffi.cdata*?
---@param tooltip string?
---@param flags number? # what the shell is to take from this, where it is not all of it
---@return boolean accepted
local function notify(window, message, hIcon, tooltip, flags)
	local data = ffi.new("WINIT_NOTIFYICONDATAW")
	data.cbSize = ffi.sizeof("WINIT_NOTIFYICONDATAW")
	data.hWnd = window.hwnd
	data.uID = TRAY_ID

	if message ~= NIM_DELETE then
		flags = flags or bit.bor(NIF_MESSAGE, NIF_ICON, NIF_TIP)
		data.uFlags = flags

		if bit.band(flags, NIF_MESSAGE) ~= 0 then
			data.uCallbackMessage = Tray.MESSAGE
		end

		if bit.band(flags, NIF_ICON) ~= 0 then
			data.hIcon = hIcon
		end

		if bit.band(flags, NIF_TIP) ~= 0 then
			copyText(data.szTip, TIP_UNITS, tooltip or "")
		end
	end

	return shell32Library.winit_Shell_NotifyIconW(message, data) ~= 0
end

local taskbarCreated

--- The message Explorer broadcasts when it starts again: every icon goes with it when it goes, and
--- the windows that had one are told only once it is back. Registered once, the first time the loop
--- asks what it is; nought is a system that could not name it, which nothing can be compared to.
---@return number id
function Tray.taskbarCreated()
	if taskbarCreated == nil then
		taskbarCreated = tonumber(user32Library.winit_RegisterWindowMessageW(
			kernel32.utf8ToWide("TaskbarCreated")))
	end

	return taskbarCreated
end

--- The menu these choices make, in the order they are drawn: a line of the window's own for each
--- choice, its tick or its grey where the choice says so, and the rule a separator is. The command
--- each choice comes back as is the second answer, which is how the menu's own answer is turned
--- back into the id the app was given.
---@param items winit.TrayItem[]
---@return ffi.cdata*? menu
---@return table<number, string> ids
function Tray.buildMenu(items)
	local menu = user32Library.winit_CreatePopupMenu()
	if menu == nil then
		return nil, {}
	end

	---@type table<number, string>
	local ids = {}
	local command = 0
	local position = 0
	local default = nil

	for _, item in ipairs(items) do
		if item.separator then
			user32Library.winit_AppendMenuW(menu, MF_SEPARATOR, 0, nil)
		else
			command = command + 1
			ids[command] = item.id

			local flags = MF_STRING
			if item.checked then flags = bit.bor(flags, MF_CHECKED) end
			if item.disabled then flags = bit.bor(flags, MF_GRAYED) end

			user32Library.winit_AppendMenuW(menu, flags, command, kernel32.utf8ToWide(item.label or ""))

			if item.default then default = position end
		end

		position = position + 1
	end

	-- The one the menu opens on, which the shell draws in bold: the window itself, where the
	-- program says which of its choices that is.
	if default ~= nil then
		user32Library.winit_SetMenuDefaultItem(menu, default, MF_BYPOSITION)
	end

	return menu, ids
end

--- Opens the window's menu where the pointer is and returns the id of what was picked from it.
--- The menu is the shell's own: it is built here, shown here and let go of here, and while it is
--- open the pointer and the keyboard are its -- which is why this returns only when it closes.
---@param window winit-win32.Window
---@param items winit.TrayItem[]
---@return string? id
local function openMenu(window, items)
	local menu, ids = Tray.buildMenu(items)
	if menu == nil then
		return nil
	end

	-- The icon's menu is drawn for the window, so the window has to be the one in front of it: a
	-- menu shown for a window behind another will not close when the pointer goes elsewhere.
	local point = user32.Point()
	user32.getCursorPos(point)
	user32Library.winit_SetForegroundWindow(window.hwnd)

	local picked = tonumber(user32Library.winit_TrackPopupMenuEx(menu,
		bit.bor(TPM_RIGHTBUTTON, TPM_NONOTIFY, TPM_RETURNCMD), point.x, point.y, window.hwnd, nil))

	-- The shell holds the menu's input until the window it was shown for hears something after it:
	-- without this, the next click goes to a menu that is no longer there.
	user32Library.winit_PostMessageW(window.hwnd, WM_NULL, 0, 0)
	user32Library.winit_DestroyMenu(menu)

	return ids[picked]
end

--- Puts the window's icon in the notification area, or changes the one already there -- its picture,
--- its tooltip, and the menu a right click opens. Changing it in place rather than taking it out and
--- putting it back is what keeps it from flickering and from losing its place beside the clock, and
--- nothing is told to the shell that has not changed: a program that keeps its tooltip up to date
--- after every message says so only when the track it names is another one.
---@param window winit-win32.Window
---@param tray winit.Tray
---@return boolean accepted
function Tray.set(window, tray)
	local icon = assert(tray.icon, "A tray icon needs a picture")
	assert(icon.width > 0 and icon.height > 0, "A tray icon needs a picture with a size")

	local state = window.tray
	if state == nil then
		state = { added = false }
		window.tray = state
	end

	local previous = state.hIcon
	local hIcon = previous

	-- The same picture is the same icon: the one the shell has is kept, and scaling it again would
	-- be work nobody sees. The menu is the window's own rather than the shell's, so a menu that
	-- changed is not a reason to say anything to the shell either.
	if previous == nil or state.iconWidth ~= icon.width or state.iconHeight ~= icon.height
		or state.iconRgba ~= icon.rgba then
		local width, height = iconSize()
		hIcon = makeIcon(width, height, scaledPixels(icon, width, height))

		if hIcon == nil then
			return false
		end
	end

	local pictureChanged = hIcon ~= previous
	local tipChanged = state.tooltip ~= tray.tooltip

	if state.added and not pictureChanged and not tipChanged then
		state.menu = tray.menu
		return true
	end

	local message = state.added and NIM_MODIFY or NIM_ADD
	local flags = 0

	-- The callback message is the icon's to be told about at all, and is set where it is put there;
	-- a change to it is not something an icon that is already there has. What a modify says is only
	-- what changed: the picture, the tip, or both.
	if not state.added then
		flags = NIF_MESSAGE
	end

	if pictureChanged or not state.added then
		flags = bit.bor(flags, NIF_ICON)
	end

	if tipChanged or not state.added then
		flags = bit.bor(flags, NIF_TIP)
	end

	if not notify(window, message, hIcon, tray.tooltip, flags) then
		if pictureChanged then
			user32Library.winit_DestroyIcon(hIcon)
		end

		return false
	end

	-- The shell has the new picture now, and the old one is nobody's.
	if pictureChanged and previous ~= nil then
		user32Library.winit_DestroyIcon(previous)
	end

	state.hIcon = hIcon
	state.iconWidth, state.iconHeight, state.iconRgba = icon.width, icon.height, icon.rgba
	state.tooltip = tray.tooltip
	state.menu = tray.menu
	state.added = true

	return true
end

--- Puts back an icon the shell lost, which is what Explorer starting again does to every icon --
--- and what the TaskbarCreated message is for. Nothing is re-added where there is no icon to add.
---@param window winit-win32.Window
---@return nil
function Tray.refresh(window)
	local state = window.tray
	if state == nil or state.hIcon == nil then
		return nil
	end

	if notify(window, NIM_ADD, state.hIcon, state.tooltip) then
		state.added = true
	end

	return nil
end

--- Takes the icon out of the notification area, and the picture it was showing with it. What the
--- window said of its menu goes too: a window whose icon is gone has none to open.
---@param window winit-win32.Window
---@return nil
function Tray.remove(window)
	local state = window.tray
	if state == nil then
		return nil
	end

	if state.added then
		notify(window, NIM_DELETE)
		state.added = false
	end

	if state.hIcon ~= nil then
		user32Library.winit_DestroyIcon(state.hIcon)
		state.hIcon = nil
	end

	state.menu = nil

	return nil
end

--- What one of the icon's messages means. A left click is the icon being activated; a right click
--- or the keyboard's context key opens the menu, and the answer to it is what was picked from it.
--- A pointer merely moving over the icon, or the shell saying something about it, is nothing.
---@param window winit-win32.Window
---@param code number # the mouse or keyboard message the shell sent, or WM_CONTEXTMENU
---@return string? name # "trayClick" or "trayMenu"
---@return string? id # what was picked, where the menu was opened
function Tray.message(window, code)
	local state = window.tray
	if state == nil or not state.added then
		return nil
	end

	if code == WM_LBUTTONUP then
		return "trayClick"
	end

	if code == WM_RBUTTONUP or code == WM_CONTEXTMENU then
		if state.menu == nil or #state.menu == 0 then
			return "trayMenu"
		end

		return "trayMenu", openMenu(window, state.menu)
	end

	return nil
end

return Tray
