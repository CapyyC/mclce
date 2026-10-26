--!strict
-- Tiny benchmark helper: runs fn(iterations) and reports ns/op plus any
-- algorithmic work counters returned by fn.
local Bench = {}

Bench.quick = false

function Bench.run(name: string, iterations: number, fn: (n: number) -> { [string]: number }?)
	local n = if Bench.quick then math.max(1, iterations // 20) else iterations
	fn(math.max(1, n // 10)) -- warm-up
	local t0 = os.clock()
	local counters = fn(n)
	local dt = os.clock() - t0
	local extra = ""
	if counters then
		local keys: { string } = {}
		for k: string in counters do
			table.insert(keys, k)
		end
		table.sort(keys)
		for _, k in keys do
			extra ..= string.format(" %s=%s", k, tostring(counters[k]))
		end
	end
	print(string.format("%-40s %10d ops %12.1f ns/op%s", name, n, dt / n * 1e9, extra))
end

return Bench
