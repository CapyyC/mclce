-- Test runner. Usage: luau tests/run.luau -a ./shared/Foo.spec [...] [--bench]
local TestKit = require("./TestKit")

local args = { ... }
local filter: string? = nil
local files = {}
for _, a in args do
	if string.sub(a, 1, 9) == "--filter=" then
		filter = string.sub(a, 10)
	else
		table.insert(files, a)
	end
end

local passed, failed = 0, 0
local failures = {}
local t0 = os.clock()
for _, file in files do
	local ok, spec = pcall(require, file)
	if not ok then
		failed += 1
		table.insert(failures, file .. " (load): " .. tostring(spec))
		continue
	end
	if type(spec) == "function" then
		local okReg, errReg = pcall(spec, TestKit)
		if not okReg then
			failed += 1
			table.insert(failures, file .. " (register): " .. tostring(errReg))
		end
	end
	for _, c in TestKit._take() do
		if filter and not string.find(c.name, filter, 1, true) then
			continue
		end
		local okCase, err = pcall(c.fn)
		if okCase then
			passed += 1
		else
			failed += 1
			table.insert(failures, file .. " :: " .. c.name .. "\n    " .. tostring(err))
		end
	end
end

for _, f in failures do
	print("FAIL " .. f)
end
print(string.format("%d passed, %d failed (%.2fs)", passed, failed, os.clock() - t0))
if failed > 0 then
	error("test failures", 0)
end
