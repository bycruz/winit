-- Calling a COM object's methods from LuaJIT.
--
--   local com = require("winit-win32.com")
--   local show = com.method(dialog, 3, "HRESULT (*)(void *, HWND)")
--   show(dialog, owner)
--
-- A COM object is a pointer to a pointer to an array of function pointers, so what is dereferenced
-- twice is the vtable: an object cast once is the vtable pointer, and one cast to `void **` and read
-- is the same thing but typed as `void *`, which nothing can be indexed through -- an array element
-- of an incomplete type has no size. The cast below is the three stars that make the second
-- dereference mean the array of methods.

local ffi = require("ffi")

local com = {}

--- One method of a COM object, as a function pointer of the shape the method is.
---@param object ffi.cdata* # The interface pointer
---@param index number # Its slot in the vtable, from nought, after the three IUnknown ones
---@param signature string # Its C type, which is what a call through it is cast to
---@return ffi.cdata* method
function com.method(object, index, signature)
	local vtable = ffi.cast("void ***", object)[0]

	return ffi.cast(signature, vtable[index])
end

return com
