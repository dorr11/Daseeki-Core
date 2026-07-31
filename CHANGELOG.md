# Changelog

## Unreleased
- Fixed: a font the game client cannot read no longer blanks the UI. The client can
  only load font FILES that were on disk when it STARTED — a font shipped or installed
  during a session resolves to a valid path but loads as nothing, so every FontString
  on that face draws INVISIBLE. A /reload does not fix it; only a full game restart
  does. This is what made the Channel input look untypable and the Copy-bundle dialog
  look blank the day the bundled Fira Sans Condensed became the default face.
  Core now PROVES a face renders (hidden probe FontString: SetFont's success return,
  the GetFont readback, and a zero-width differential against Friz Quadrata) before
  committing it — at login, on every apply, and when a face is chosen from the picker.
  A face that fails takes the whole session back to Friz Quadrata with one plain chat
  line explaining that a full game restart is needed. Your saved font choice is NOT
  changed, so the next proper restart silently gives you the font you picked. Font
  consumers across the suite are re-notified (OnFontChanged) so everything re-skins to
  the fallback together.
- New API: UI.IsFaceFallback() (is this session on the fallback face, and which face
  failed) and UI.FontFileRaw() (the picked path, unverified — for diagnostics).
  UI.FontFile() is unchanged for callers but now returns only a verified face.
- New headless self-test harness (`harness/run-selftests.cmd`, real Lua 5.1, mirrors
  the Daseeki-Nexus pattern): parse-gates every .lua the .toc lists, covers the font
  load guard (all four ways a client can report an unreadable face, the picker path,
  fallback lift, notice-once, saved-choice preservation, and no false fallbacks), and
  firewalls the globals core.lua + theme.lua are allowed to publish.
- Font picker added to Core > Appearance: choose from the 6 WoW built-in faces (Friz
  Quadrata, Arial Narrow, Morpheus, Skurri, 2002, 2002 Bold) plus any LibSharedMedia
  fonts registered by WeakAuras, Details, and other addons — merged at runtime, no
  shipped font files. Selecting a face re-skins the whole suite live.
- New Text size slider (85–130%, default 100%) scales all suite text at once.
- Body text, micro-labels, and numerals now follow the picked face; the fresh-install
  default is Friz Quadrata (fixes the previously-thin ARIALN labels/numerals). Ceremonial
  headers stay MORPHEUS by brand law and never follow the picker.
- New API: UI.SetFont / GetFont / FontNames / SetFontScale / GetFontScale / FontFile /
  OnFontChanged / RegisterFont. Choices persist (DaseekiCoreDB.fontChoice / fontScale).
- Field Ledger material now reads at game gamma (BRAND_SPEC §4/§5a): the grain substrate
  is regenerated as a parchment-white two-octave texture (±6% amplitude ceiling) so raising
  the veil lightens the ground gutters toward parchment instead of muddying them dark, and
  the aged-edge vignette + bronze keyline strengthen a visible step. New material dial in
  Core > Appearance (Subtle / Standard / Strong; Standard is default); `/daseekiui debug
  material` cycles it live for A/B. The choice persists (DaseekiCoreDB.materialPreset).

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
