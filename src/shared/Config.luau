--!strict
-- Tunables shared by server and client. Gameplay constants that mirror the
-- Legacy game are labelled; engine/budget values are our own.
local Config = {}

Config.BLOCK_SIZE = 3 -- studs per block (R15 avatar ~5.4 studs ~ 1.8 blocks)
Config.TICK_RATE = 20 -- simulation ticks per second (Legacy/Java)

-- Streaming (chunks). Legacy console render distance is fixed and short; these
-- are per-server budgets, to be tuned with Studio measurements.
Config.SERVER_VIEW_RADIUS = 6
Config.CLIENT_VIEW_RADIUS = 6
Config.GEN_BUDGET_PER_TICK = 2 -- chunk generations per server tick
Config.SEND_BUDGET_PER_TICK = 4 -- chunk payloads per player per tick
Config.MESH_BUDGET_PER_FRAME = 2 -- section meshes per client frame
Config.MAX_LOADED_CHUNKS = 1500
Config.GEN_WORKERS = 4 -- parallel generation Actors on the server (0 = generate in the main thread)

-- Interaction (Legacy uses Java-derived reach: 4.5 survival / 5 creative).
Config.REACH_SURVIVAL = 4.5
Config.REACH_CREATIVE = 5
Config.REACH_TOLERANCE = 1.5 -- extra server-side slack for latency
Config.BREAK_TIME_TOLERANCE = 0.7 -- accept breaks after >= 70% of expected time
Config.ACTIONS_PER_SECOND = 20 -- token bucket refill
Config.ACTION_BURST = 40

-- Renderer: "parts" (greedy-box Parts, works everywhere) or "mesh"
-- (EditableMesh visuals + invisible box collision). Override at runtime with
-- workspace:SetAttribute("mclceRenderer", "mesh"). "mesh" is unverified in Studio.
Config.RENDERER = "parts"
Config.MESH_CLOCKWISE = false -- flip if faces render inside-out in Studio
Config.ATLAS_ASSET = "" -- rbxassetid of an original/licensed 16x16-tile atlas (optional)
Config.ATLAS_COLUMNS = 16

Config.WORLD_SIZE = 864 -- Classic
-- Nether coordinate scale (Java uses 8). The PS4 1.95 value is not verified;
-- 3 gives a playable 288-block Nether for Classic worlds.
Config.NETHER_SCALE = 3
Config.DEFAULT_SEED = "mclce"

return Config
