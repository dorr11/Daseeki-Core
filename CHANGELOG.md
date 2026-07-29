# Changelog

## Unreleased
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
