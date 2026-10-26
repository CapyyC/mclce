--!strict
-- Minimal deterministic test harness for the standalone Luau CLI.
-- Specs return a function(t: TestKit) that registers cases with t.test.

local TestKit = {}

export type Case = { name: string, fn: () -> () }

local cases: { Case } = {}
local currentPrefix = ""

local function fmt(v: any): string
	if type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

function TestKit.describe(name: string, body: () -> ())
	local saved = currentPrefix
	currentPrefix = currentPrefix .. name .. " > "
	body()
	currentPrefix = saved
end

function TestKit.test(name: string, fn: () -> ())
	table.insert(cases, { name = currentPrefix .. name, fn = fn })
end

function TestKit.eq(actual: any, expected: any, msg: string?)
	if actual ~= expected then
		error(string.format("%sexpected %s, got %s", msg and (msg .. ": ") or "", fmt(expected), fmt(actual)), 2)
	end
end

function TestKit.near(actual: number, expected: number, eps: number, msg: string?)
	if math.abs(actual - expected) > eps then
		error(string.format("%sexpected %s +- %s, got %s", msg and (msg .. ": ") or "", fmt(expected), fmt(eps), fmt(actual)), 2)
	end
end

function TestKit.truthy(v: any, msg: string?)
	if not v then
		error((msg or "expected truthy value") .. ", got " .. fmt(v), 2)
	end
end

function TestKit.falsy(v: any, msg: string?)
	if v then
		error((msg or "expected falsy value") .. ", got " .. fmt(v), 2)
	end
end

function TestKit.throws(fn: () -> (), pattern: string?)
	local ok, err = pcall(fn)
	if ok then
		error("expected function to throw", 2)
	end
	if pattern and not string.find(tostring(err), pattern) then
		error("error " .. fmt(tostring(err)) .. " does not match " .. fmt(pattern), 2)
	end
end

function TestKit.deepEq(a: any, b: any, path: string?)
	local p = path or "value"
	if type(a) ~= type(b) then
		error(string.format("%s: type mismatch %s vs %s", p, type(a), type(b)), 2)
	end
	if type(a) ~= "table" then
		if a ~= b then
			error(string.format("%s: expected %s, got %s", p, fmt(b), fmt(a)), 2)
		end
		return
	end
	for k, v in a do
		if b[k] == nil then
			error(string.format("%s.%s: unexpected key", p, tostring(k)), 2)
		end
		TestKit.deepEq(v, b[k], p .. "." .. tostring(k))
	end
	for k in b do
		if a[k] == nil then
			error(string.format("%s.%s: missing key", p, tostring(k)), 2)
		end
	end
end

function TestKit._take(): { Case }
	local out = cases
	cases = {}
	return out
end

return TestKit
