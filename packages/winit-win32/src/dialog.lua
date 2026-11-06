-- The system's file and folder picker, through the same COM dialog Explorer uses.
--
--   local paths = winit.FileDialog.open(window, {
--       title = "Choose tracks",
--       multiple = true,
--       filters = {{ name = "Audio", extensions = { "mp3", "flac" } }},
--   })
--
-- The call is modal: the dialog runs its own message loop until it is closed. The answer is a
-- list of filesystem paths, empty when it was cancelled.
local ffi = require("ffi")
local kernel32 = require("winapi.kernel32")

local ole32 = ffi.load("ole32")

ffi.cdef([[
	typedef int32_t HRESULT;
	typedef uint32_t ULONG;
	typedef uint32_t DWORD;
	typedef void *HWND;
	typedef uint16_t WCHAR;

	typedef struct {
		uint32_t Data1;
		uint16_t Data2;
		uint16_t Data3;
		uint8_t Data4[8];
	} WINIT_GUID;

	typedef struct {
		const WCHAR *pszName;
		const WCHAR *pszSpec;
	} WINIT_FILTERSPEC;

	HRESULT CoInitializeEx(void *reserved, DWORD coinit);
	void CoUninitialize(void);
	HRESULT CoCreateInstance(const WINIT_GUID *clsid, void *outer, DWORD context,
		const WINIT_GUID *iid, void **out);
	void CoTaskMemFree(void *memory);
]])

-- CLSID_FileOpenDialog and IID_IFileOpenDialog, as the Windows SDK spells them.
local FILE_OPEN_DIALOG = {
	0xDC1C5A9C, 0xE88A, 0x4DDE, 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7,
}
local IID_FILE_OPEN_DIALOG = {
	0xD57C7288, 0xD4AD, 0x4768, 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60,
}

local COINIT_APARTMENTTHREADED = 2
local CLSCTX_INPROC_SERVER = 1

local FOS_PICKFOLDERS = 0x20
local FOS_FORCEFILESYSTEM = 0x40
local FOS_ALLOWMULTISELECT = 0x200
local FOS_PATHMUSTEXIST = 0x800
local FOS_FILEMUSTEXIST = 0x1000
local FOS_NOCHANGEDIR = 0x8

-- The IFileDialog slots used here; GetResults is the first IFileOpenDialog method after that
-- interface's common block.
local IFileDialog_Show = 3
local IFileDialog_SetFileTypes = 4
local IFileDialog_SetFileTypeIndex = 5
local IFileDialog_SetOptions = 9
local IFileDialog_SetTitle = 17
local IFileOpenDialog_GetResults = 21

local IUnknown_Release = 2
local IShellItem_GetDisplayName = 5

-- IShellItemArray's count and item methods, after IUnknown and its property methods.
local IShellItemArray_GetCount = 7
local IShellItemArray_GetItemAt = 8

local SIGDN_FILESYSPATH = ffi.cast("int32_t", 0x80058000)

---@param fields number[]
---@return WINIT_GUID
local function guid(fields)
	local value = ffi.new("WINIT_GUID")

	value.Data1 = fields[1]
	value.Data2 = fields[2]
	value.Data3 = fields[3]
	for index = 4, 11 do value.Data4[index - 4] = fields[index] end

	return value
end

---@param object ffi.cdata*
---@param index number
---@param signature string
---@return ffi.cdata*
local function method(object, index, signature)
	local vtable = ffi.cast("void **", object)[0]
	return ffi.cast(signature, vtable[index])
end

---@param item ffi.cdata*
---@return string? path
local function itemPath(item)
	local displayOut = ffi.new("void *[1]")
	local getDisplay = method(item, IShellItem_GetDisplayName,
		"HRESULT (*)(void *, int32_t, void **)")
	local releaseItem = method(item, IUnknown_Release, "ULONG (*)(void *)")
	local path

	if getDisplay(item, SIGDN_FILESYSPATH, ffi.cast("void **", displayOut)) == 0
	and displayOut[0] ~= nil then
		path = kernel32.wideToUtf8(ffi.cast("const WCHAR *", displayOut[0]))
		ole32.CoTaskMemFree(displayOut[0])
	end

	releaseItem(item)
	return path
end

local FileDialog = {}

--- Open the Windows file dialog.
---@param window winit.Window?
---@param opts winit.FileDialog.OpenOptions?
---@return string[] paths
function FileDialog.open(window, opts)
	opts = opts or {}

	local initialized = ole32.CoInitializeEx(nil, COINIT_APARTMENTTHREADED)
	local ownsCom = initialized == 0 or initialized == 1

	if not ownsCom then
		return {}
	end

	local out = ffi.new("void *[1]")
	local created = ole32.CoCreateInstance(guid(FILE_OPEN_DIALOG), nil, CLSCTX_INPROC_SERVER,
		guid(IID_FILE_OPEN_DIALOG), ffi.cast("void **", out))
	local dialog = out[0]

	if created ~= 0 or dialog == nil then
		if ownsCom then ole32.CoUninitialize() end
		return {}
	end

	local show = method(dialog, IFileDialog_Show, "HRESULT (*)(void *, HWND)")
	local setFileTypes = method(dialog, IFileDialog_SetFileTypes,
		"HRESULT (*)(void *, uint32_t, const WINIT_FILTERSPEC *)")
	local setFileTypeIndex = method(dialog, IFileDialog_SetFileTypeIndex,
		"HRESULT (*)(void *, uint32_t)")
	local setOptions = method(dialog, IFileDialog_SetOptions, "HRESULT (*)(void *, DWORD)")
	local setTitle = method(dialog, IFileDialog_SetTitle, "HRESULT (*)(void *, const WCHAR *)")
	local getResults = method(dialog, IFileOpenDialog_GetResults, "HRESULT (*)(void *, void **)")
	local release = method(dialog, IUnknown_Release, "ULONG (*)(void *)")

	local flags = bit.bor(FOS_FORCEFILESYSTEM, FOS_PATHMUSTEXIST, FOS_NOCHANGEDIR)

	if opts.directory then
		flags = bit.bor(flags, FOS_PICKFOLDERS)
	else
		flags = bit.bor(flags, FOS_FILEMUSTEXIST)
	end

	if opts.multiple then flags = bit.bor(flags, FOS_ALLOWMULTISELECT) end
	setOptions(dialog, flags)

	if opts.title ~= nil then
		local title = kernel32.utf8ToWide(opts.title)

		if title ~= nil then setTitle(dialog, title) end
	end

	-- What a filter is to COM is two wide strings, and the array of pairs has to stay alive until
	-- Show returns: the strings the pairs point at live in `kept` for the same reason.
	local kept = {}
	local specs = nil

	if opts.filters ~= nil and #opts.filters > 0 then
		specs = ffi.new("WINIT_FILTERSPEC[?]", #opts.filters)

		for at, filter in ipairs(opts.filters) do
			local patterns = {}

			for _, extension in ipairs(filter.extensions or {}) do
				extension = tostring(extension):gsub("^%.", "")

				if extension ~= "" then patterns[#patterns + 1] = "*." .. extension end
			end

			local spec = #patterns > 0 and table.concat(patterns, ";") or "*.*"
			local name = kernel32.utf8ToWide(filter.name or "Files")
			local pattern = kernel32.utf8ToWide(spec)

			if name == nil or pattern == nil then
				specs = nil
				break
			end

			specs[at - 1].pszName = name
			specs[at - 1].pszSpec = pattern
			kept[#kept + 1], kept[#kept + 1] = name, pattern
		end

		if specs ~= nil then
			setFileTypes(dialog, #opts.filters, specs)
			setFileTypeIndex(dialog, 1)
		end
	end

	local owner = window ~= nil and window.hwnd or nil
	local shown = show(dialog, owner)
	local paths = {}

	if shown == 0 then
		local results = ffi.new("void *[1]")

		if getResults(dialog, ffi.cast("void **", results)) == 0 and results[0] ~= nil then
			local array = results[0]
			local count = ffi.new("uint32_t[1]")
			local getCount = method(array, IShellItemArray_GetCount,
				"HRESULT (*)(void *, uint32_t *)")
			local getItemAt = method(array, IShellItemArray_GetItemAt,
				"HRESULT (*)(void *, uint32_t, void **)")
			local releaseArray = method(array, IUnknown_Release, "ULONG (*)(void *)")

			if getCount(array, count) == 0 then
				for at = 0, tonumber(count[0]) - 1 do
					local itemOut = ffi.new("void *[1]")

					if getItemAt(array, at, ffi.cast("void **", itemOut)) == 0
					and itemOut[0] ~= nil then
						local path = itemPath(itemOut[0])

						if path ~= nil then paths[#paths + 1] = path end
					end
				end
			end

			releaseArray(array)
		end
	end

	release(dialog)

	if ownsCom then ole32.CoUninitialize() end

	return paths
end

return FileDialog
