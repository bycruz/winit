-- The desktop's file and folder picker on X11. There is no one file dialog in the X11 protocol: a
-- desktop provides one as a program of its own, and XDG_CURRENT_DESKTOP is the standard name for
-- which desktop is running. KDE's chooser is kdialog; the GTK desktops' is zenity; yad is the
-- fallback for a desktop that has neither. They are spawned directly -- no shell, no quoting.
local process = require("process")

local FileDialog = {}

---@param value string?
---@return string
local function folded(value)
	return (value or ""):lower()
end

---@return boolean
local function prefersKde()
	-- The first of these that says anything is the one that is running; a stale DESKTOP_SESSION
	-- under a GNOME session must not send a GTK desktop to kdialog.
	for _, variable in ipairs({ "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "DESKTOP_SESSION" }) do
		local desktop = folded(os.getenv(variable))

		if desktop ~= "" then
			return desktop:find("kde", 1, true) ~= nil
				or desktop:find("plasma", 1, true) ~= nil
		end
	end

	return false
end

---@param filters winit.FileFilter[]?
---@return string[] arguments
local function zenityFilters(filters)
	local arguments = {}

	for _, filter in ipairs(filters or {}) do
		local patterns = {}

		for _, extension in ipairs(filter.extensions or {}) do
			extension = tostring(extension):gsub("^%.", "")

			if extension ~= "" then patterns[#patterns + 1] = "*." .. extension end
		end

		if #patterns > 0 then
			arguments[#arguments + 1] = "--file-filter=" .. (filter.name or "Files") .. " | "
				.. table.concat(patterns, " ")
		end
	end

	return arguments
end

---@param filters winit.FileFilter[]?
---@return string?
local function kdialogFilter(filters)
	local groups = {}

	for _, filter in ipairs(filters or {}) do
		local patterns = {}

		for _, extension in ipairs(filter.extensions or {}) do
			extension = tostring(extension):gsub("^%.", "")

			if extension ~= "" then patterns[#patterns + 1] = "*." .. extension end
		end

		if #patterns > 0 then
			groups[#groups + 1] = (filter.name or "Files") .. " ("
				.. table.concat(patterns, " ") .. ")"
		end
	end

	if #groups == 0 then return nil end

	return table.concat(groups, ";;")
end

---@param tool string
---@param args string[]
---@return string? output
---@return "ok"|"cancelled"|"missing"
local function run(tool, args)
	local code, output = process.exec(tool, args)

	if code == nil then return nil, "missing" end

	output = (output or ""):gsub("[\r\n]+$", "")

	if code ~= 0 or output == "" then return nil, "cancelled" end

	return output, "ok"
end

---@param output string
---@param multiple boolean?
---@return string[] paths
local function pathsOf(output, multiple)
	if not multiple then return { output } end

	local paths = {}

	for path in output:gmatch("[^\n]+") do paths[#paths + 1] = path end

	return paths
end

--- Open the desktop's file dialog.
---@param _window winit.Window?
---@param opts winit.FileDialog.OpenOptions?
---@return string[] paths
function FileDialog.open(_window, opts)
	opts = opts or {}

	local title = opts.title or (opts.directory and "Choose a folder" or "Choose a file")
	local home = os.getenv("HOME") or "."
	local multiple = opts.multiple == true
	local filters = opts.filters

	local choices = prefersKde() and { "kdialog", "zenity", "yad" }
		or { "zenity", "kdialog", "yad" }

	for _, tool in ipairs(choices) do
		local args
		local output

		if tool == "kdialog" then
			if opts.directory then
				-- kdialog's directory chooser selects one folder; a multiple-folder request is
				-- left to zenity or yad after this one has had its turn.
				if multiple then goto continue end
				args = { "--getexistingdirectory", home, "--title", title }
			else
				args = { "--getopenfilename", home }

				local filter = kdialogFilter(filters)
				if filter ~= nil then args[#args + 1] = filter end

				args[#args + 1] = "--title"
				args[#args + 1] = title

				if multiple then
					args[#args + 1] = "--multiple"
					args[#args + 1] = "--separate-output"
				end
			end
		elseif tool == "zenity" then
			args = { "--file-selection", "--title", title }

			if opts.directory then args[#args + 1] = "--directory" end
			if multiple then
				args[#args + 1] = "--multiple"
				args[#args + 1] = "--separator=\n"
			end

			for _, argument in ipairs(zenityFilters(filters)) do args[#args + 1] = argument end
		else
			args = { "--file", "--title", title }

			if opts.directory then args[#args + 1] = "--directory" end
			if multiple then
				args[#args + 1] = "--multiple"
				args[#args + 1] = "--separator=\n"
			end

			for _, argument in ipairs(zenityFilters(filters)) do args[#args + 1] = argument end
		end

		local status
		output, status = run(tool, args)

		if status == "ok" then return pathsOf(output, multiple) end
		if status == "cancelled" then return {} end

		::continue::
	end

	return {}
end

return FileDialog
