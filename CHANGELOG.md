# Changelog

## Unreleased

- Changed: Daseeki Core is now licensed **All Rights Reserved** rather than MIT, matching the rest of the suite; the bundled Fira Sans Condensed font keeps its own SIL Open Font License 1.1 (`fonts/OFL.txt`) and is unaffected.

## 2.2.0 — 2026-08-03

### Added
- **A new look for the suite: Field Ledger.** The settings window is redressed as worn
  ink on parchment — warm dark grounds, a faint paper grain, aged edges and a thin bronze
  keyline, with the suite crimson kept for selection and urgency. Field Ledger is the
  theme a fresh install starts on. If you have already picked a theme, your choice is
  left exactly as it was; switch to it from Core > Appearance whenever you like.
- **New "Daseeki" theme** — the owner's original 1.x skin rebuilt from the real thing:
  near-black window grounds, blood-red accents and borders, warm gold titles. Pick it
  in Core > Appearance if you miss the old look.
- **Material dial** (Core > Appearance): **Subtle / Standard / Strong** sets how strongly
  the parchment grain, the aged edge and the bronze keyline read on your monitor.
  Standard is the default, and `/daseekiui debug material` cycles the three live so you
  can compare them side by side. Your choice is remembered.
- **Font picker** (Core > Appearance): choose the face the whole suite is drawn in.
  Daseeki Core now ships with **Fira Sans Condensed Medium** (SIL Open Font License 1.1)
  and uses it by default on a fresh install — this replaces the thin Arial Narrow that
  made labels and numerals hard to read. Alongside it you get the six built-in WoW faces
  (Friz Quadrata, Arial Narrow, Morpheus, Skurri, 2002, 2002 Bold) plus any font
  registered with LibSharedMedia by WeakAuras, Details or another addon, merged in at
  runtime. Picking a face re-skins every Daseeki window immediately. Ceremonial headers
  stay Morpheus by design and never follow the picker. If you already had a font chosen,
  it is not changed.
- **Text size slider** (85–130%, default 100%) scales all suite text at once. Both the
  face and the size are remembered.

### Changed
- Settings window sidebar: the **Core** group (Appearance) now sits above the **Suite**
  group, and the suite addons under it are listed alphabetically instead of in whatever
  order they happened to load. The order is settled when the sidebar is drawn, so an
  addon that loads late in the session still lands in its alphabetical place rather than
  at the bottom — the list reads the same every session.
- Settings window title bar: the **Daseeki Suite** wordmark is painted in your active
  theme's accent colour (the suite crimson on the shipped themes) instead of a fixed
  cream, matching the Nexus wordmark and the Raid Prep title. It re-tints live when you
  switch theme, so a theme with a different accent gets its own. The version number
  beside it stays muted — it is metadata, not part of the lockup.

### Fixed
- **A font your client cannot read no longer blanks the UI.** WoW can only load font
  files that were already on disk when the game *started* — a font installed or shipped
  mid-session resolves to a valid path but loads as nothing, so every piece of text on
  that face draws invisible. A /reload does not fix it; only a full game restart does.
  This is what made the Channel input look untypable and the Copy-bundle dialog look
  blank on the day the bundled Fira Sans Condensed became the default face. Core now
  proves a face actually renders before committing to it — at login, on every apply, and
  when you pick a face from the picker. A face that fails puts the whole session back on
  Friz Quadrata with one plain chat line explaining that a full game restart is needed,
  and every Daseeki window re-skins to the fallback together. Your saved font choice is
  **not** changed, so the next proper restart silently gives you the font you picked.
- The Field Ledger material now reads correctly at real in-game gamma. The grain is a
  parchment-white substrate, so turning the material up lightens the gutters between
  panels toward paper instead of muddying them dark, and the aged edge and bronze
  keyline make a step you can actually see.

### For addon authors
- `DaseekiSuite.CORE_VERSION` (this Core's version string, read from the .toc once at
  load) and `DaseekiSuite.RequireCore(minVersion[, caller])` — the cross-addon version
  guard. Call it before touching an API a given Core introduced; against an older Core
  you get `false` plus one plain chat line ("… needs Daseeki Core v2.2.0, v2.0.0
  installed — update Daseeki-Core") instead of a Lua error, and the feature simply stays
  off. `DaseekiSuite.CompareVersions(a, b)` is exposed alongside it. Guard the ledger-kit
  APIs on 2.2.0.
- `DaseekiSuite:GetSuiteOrder()` (registered addon ids in sidebar order) and
  `DaseekiSuite:GetNavPlan([activeAddonId])` (the sidebar's ordered entry list as plain
  data). The nav order now lives in core.lua and hub.lua only renders it; the hub's
  default selection uses the same order, so "first addon" means the first one shown.
- Font API: `UI.SetFont` / `GetFont` / `FontNames` / `SetFontScale` / `GetFontScale` /
  `FontFile` / `OnFontChanged` / `RegisterFont`, plus `UI.IsFaceFallback()` (is this
  session on the fallback face, and which face failed) and `UI.FontFileRaw()` (the picked
  path, unverified — for diagnostics). `UI.FontFile()` is unchanged for callers but now
  returns only a face that has been proven to render. Choices persist in
  `DaseekiCoreDB.fontChoice` / `fontScale`.
- Material API: `UI.SetMaterialPreset` / `GetMaterialPreset` / `GetMaterialPresetNames`
  (`subtle` | `standard` | `strong`); persists in `DaseekiCoreDB.materialPreset`.

### Internal
- New headless self-test harness (`harness/run-selftests.cmd`, real Lua 5.1, mirroring
  the Daseeki-Nexus pattern): parse-gates every .lua the .toc lists, covers the font load
  guard and the cross-addon version guard, and firewalls the globals core.lua and
  theme.lua are allowed to publish. Not shipped in the packaged addon.

## 2.0.0
- Complete settings-window overhaul: new DaseekiUI framework replaces the old fixed hub.
- Sidebar navigation (suite addons + Core pages) with breadcrumb title bar.
- Resizable window (minimum 1140x560, size remembered per character).
- Theme system with an end-user picker (Core > Appearance): six themes ship in 2.0.0 —
  Ashenvale Gold, Neutral Slate, Orgrimmar Ember, Stormwind Regalia, Felwood, and
  Winterspring Frost; themes re-skin live with no /reload.
- Every settings pane now scrolls and clips — settings can no longer render outside the
  window or overlap.
- New widget toolkit (checkboxes, sliders, dropdowns, segmented toggles, lists, editor
  cards) with consistent spacing and mouse-wheel scrolling everywhere.
- /daseekiui debug toggles a layout-outline overlay for troubleshooting.
- Older Daseeki addon versions still render via a built-in compatibility path.

## 1.0.0
- Initial CurseForge release.
