# Daseeki Core

Shared options hub and UI toolkit for the Daseeki addon suite (WoW Classic Era).

Daseeki Core is not a standalone addon — it provides:

- A unified, ElvUI/Details-style options window that other Daseeki addons plug their settings into.
- A shared widget toolkit (`widgets.lua`) and dialog system (`dialogs.lua`) used across the suite.
- A minimap button (`minimap.lua`) and `/daseeki` slash command (`slash.lua`) for opening the hub.
- Skinning helpers (`skin.lua`) so all Daseeki addons share a consistent look.
- A persisted addon-performance log (`perf.lua`, `DaseekiCoreDB.perfLog`) built on the
  client's `C_AddOnProfiler`: a bounded ring of CPU snapshots covering every loaded
  Daseeki addon plus the heaviest addons overall, read back with `/daseeki perf`.

## Requires

Nothing — Core has no dependencies and is the foundation the rest of the suite (Bags, Buff Tracker, Armory, Raid Mechanics, Raid Prep) optionally depends on.

## Companion addons

- Daseeki Bags
- Daseeki Buff Tracker
- Daseeki Armory
- Daseeki Raid Mechanics
- Daseeki Raid Prep
