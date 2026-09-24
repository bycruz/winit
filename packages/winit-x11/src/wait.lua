local ffi = require("ffi")
local x11 = require("x11api")

-- A wait with a time on it, which is what a screen with something to do on its own needs: a
-- caret that blinks is a frame half a second away, and Xlib's own wait -- XNextEvent -- blocks
-- until an event arrives, of which an idle window has none. What it waits on is the socket the
-- display talks on, which `x11.connectionNumber` is.
ffi.cdef [[
	struct wlx_pollfd { int fd; short events; short revents; };
	int poll(struct wlx_pollfd *fds, unsigned long count, int milliseconds);

	struct wlx_timespec { long tv_sec; long tv_nsec; };
	int clock_gettime(int clock_id, struct wlx_timespec *tp);
]]

local POLLIN = 1
local CLOCK_MONOTONIC = 1

local waitFds = ffi.new("struct wlx_pollfd[1]")
local timestamp = ffi.new("struct wlx_timespec[1]")

---@class winit-x11.Wait
local Wait = {}

--- Waits until the display has something to be read from it, or the time runs out.
---@param display x11.ffi.Display
---@param milliseconds number
---@return boolean # Whether the display became readable
function Wait.readable(display, milliseconds)
	waitFds[0].fd = x11.connectionNumber(display)
	waitFds[0].events = POLLIN
	waitFds[0].revents = 0

	return ffi.C.poll(waitFds, 1, milliseconds) > 0
end

--- Seconds since a fixed point, which is what a deadline is measured against. The wall clock is
--- not that: a program -- or a person -- can set it while something is waiting on it, and a
--- deadline that moved with it would fire late, or never.
---@return number
function Wait.monotonic()
	ffi.C.clock_gettime(CLOCK_MONOTONIC, timestamp)

	return tonumber(timestamp[0].tv_sec) + tonumber(timestamp[0].tv_nsec) / 1e9
end

return Wait
