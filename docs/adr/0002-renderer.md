# ADR 0002 — Renderer: greedy-box Parts first, EditableMesh second

## Context
Roblox offers (a) Parts, (b) runtime meshes via `AssetService:CreateEditableMesh` +
`CreateMeshPartAsync`, which have per-device memory budgets, can fail to allocate, and whose
availability and limits change between releases. There are no custom shaders, so atlas UV tiling
across greedy quads is impossible (no `fract()` in a shader).

## Decision
- Meshing is render-neutral: `SectionMesher` emits culled (optionally greedy) quads with texture ids;
  `BoxMesher` emits greedy boxes where fully hidden opaque blocks are wildcards.
- First renderer (`src/client/ChunkRenderer.luau`) uses one anchored Part per box with block
  colour + Roblox material. Works everywhere, gives collision for the client-owned character
  for free, no texture fidelity.
- Next renderer: EditableMesh per section from `SectionMesher` quads with `greedy=false` against a
  texture atlas (needs an original or licensed atlas uploaded as an asset — not in the repo), with
  the Part renderer kept as fallback when EditableMesh allocation fails. Collision would then come
  from invisible box Parts (`BoxMesher`, CanCollide only, Transparency 1).

## Consequences
- Part counts must be measured in Studio (TESTING.md lists it). If too high, reduce view radius,
  or merge distant sections into coarser LOD boxes.

## Update (session 1)
- `MeshRenderer` (opt-in: `workspace:SetAttribute("mclceRenderer", "mesh")` or `Config.RENDERER`)
  builds one MeshPart per section/layer from `MeshBuilder` batches (vertex colours with classic face
  shading; atlas UVs when `Config.ATLAS_ASSET` is set, which forces non-greedy quads). Collision uses
  invisible greedy boxes. After 3 EditableMesh failures it permanently falls back to Parts.
- Mock numbers at radius 6: Part renderer ~22k visible Parts; mesh renderer 507 MeshParts
  (~170k triangles) + ~21k invisible collision boxes.
- TODO: build collision boxes only within ~2 chunks of the player; unknown whether Roblox's
  winding convention matches `Config.MESH_CLOCKWISE = false` (flip if faces look inside-out).
