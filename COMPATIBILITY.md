# Compatibility matrix (target: Minecraft PS4 Edition 1.95)

Labels: **VT** verified against target · **RS** supported by related-version source/doc · **INF** inferred ·
**PART** partially implemented · **NI** not implemented · **UNK** unknown.

No target source/binary was available, so nothing is VT. "RS" here means public documentation of
Legacy Console / classic numeric-ID Minecraft (not code).

| Area | Status | Evidence / notes |
|---|---|---|
| Numeric block IDs + 4-bit data | RS, PART | Classic pre-flattening table; LCE never adopted string IDs. ~75 blocks defined. |
| Block hardness values | RS | Public values; tool tiers per classic rules. |
| World height 0..255 | RS | LCE uses 256-high worlds. |
| Finite world sizes (Classic 864, Small 1024, Medium 3072, Large 5120) | RS | PS4 world-size options; border enforced in World. |
| World generation | NI | |
| Meshing/rendering | NI | Roblox-specific; not a fidelity item. |
