local Bench = require("./Bench")
local suites = { "./coords.bench", "./worldgen.bench" }
for _, a in { ... } do
	if a == "--quick" then
		Bench.quick = true
	end
end
for _, s in suites do
	require(s)(Bench)
end
