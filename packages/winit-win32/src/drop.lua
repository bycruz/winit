local shell32 = require("winapi.shell32")
local user32 = require("winapi.user32")

--- The files a drop carried, and where it was let go of -- in the window's own corner, which is
--- where everything else a window asks about a pointer comes back in.
---@param drop winapi.shell32.ffi.HDROP
---@return string[] paths
---@return number x
---@return number y
return function(drop)
	local count = shell32.dragQueryFileCount(drop)
	local paths = {}

	for index = 0, count - 1 do
		paths[#paths + 1] = shell32.dragQueryFile(drop, index)
	end

	local point = user32.Point()
	local inside = shell32.dragQueryPoint(drop, point)

	-- safety: the drop is the shell's while it is being read and belongs to the message that
	-- brought it, so it is let go of here rather than left for whoever reads it next -- a drop
	-- read twice is not a thing
	shell32.dragFinish(drop)

	if inside then
		return paths, point.x, point.y
	end

	return paths, 0, 0
end
