--!strict
-- Face direction table shared by mesher, raycast and renderer.
-- Index: 0 +X, 1 -X, 2 +Y, 3 -Y, 4 +Z, 5 -Z.
local Faces = {}

Faces.EAST = 0
Faces.WEST = 1
Faces.UP = 2
Faces.DOWN = 3
Faces.SOUTH = 4
Faces.NORTH = 5

Faces.DX = { [0] = 1, -1, 0, 0, 0, 0 }
Faces.DY = { [0] = 0, 0, 1, -1, 0, 0 }
Faces.DZ = { [0] = 0, 0, 0, 0, 1, -1 }
Faces.OPPOSITE = { [0] = 1, 0, 3, 2, 5, 4 }

return Faces
