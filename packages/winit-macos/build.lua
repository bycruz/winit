-- The backend's own half is Objective-C rather than Lua -- see `src/shim.m` for why -- so what
-- this package is installed with is a page of Lua over a shared library built from it.
--
-- What the compiler is asked for is a dynamically loadable library beside the entry point, under
-- the name `shim`, which is what the Lua side loads. The frameworks named are the ones the shim
-- reaches into: Cocoa for the window and the events, CoreGraphics for the pointer a grab holds.

local build = require("lde-build")

-- Another platform has nothing to build this for, and no business building it: a monorepo runs
-- every package's tests wherever it is run, and this half is the one the program it is installed
-- into would never ask for.
if jit.os ~= "OSX" then
	return
end

-- What a mac ships with is a compiler, since a platform whose C libraries are only reachable
-- through one is one where nothing else could be built at all: the command line tools set it up,
-- and what this asks for is clang and the frameworks around it.
local _, stderr = build:cc({
	"-fobjc-arc",
	"-dynamiclib",
	"-fPIC",
	"-framework", "Cocoa",
	"-framework", "CoreGraphics",
	"-o", build.outDir .. "/shim.so",
	build.outDir .. "/shim.m"
})

-- Whether the library is there afterwards is what says it compiled, rather than the compiler's own
-- word for it: a warning is not a failure, and a failure is not a warning.
if not build:exists("shim.so") then
	error("Failed to build the macos shim: " .. tostring(stderr))
end
