# CurseForge Description — Daseeki Core

<!-- Canonical CurseForge project description. Update here first, then paste to
     https://www.curseforge.com/wow/addons/daseeki-core (project 1592402).
     Last synced: 2026-08-03 (v2.2.0). -->

Daseeki Core is the shared foundation for the Daseeki addon suite. It isn't a standalone addon on its own — install it alongside any other Daseeki addon to get a single, unified options window instead of separate config screens scattered across each addon.

## Features
- Combined options hub that other Daseeki addons register their settings into automatically — Core's own section on top, your installed suite addons listed alphabetically below
- **Themes**: the suite ships with the Field Ledger look (worn ink on parchment) plus eight more palettes, including the original near-black-and-blood-red "Daseeki" skin. Pick one in Core → Appearance and every Daseeki addon re-skins instantly
- **Font picker**: choose the face the whole suite is drawn in — Core bundles Fira Sans Condensed Medium (SIL OFL) as the new default for readability, alongside the built-in WoW faces and anything your other addons registered with LibSharedMedia. A text-size slider (85–130%) scales all suite text at once
- **Material dial**: Subtle / Standard / Strong controls how much parchment grain and edge detail the themes render on your monitor
- Shared widget toolkit and dialog system, so every Daseeki addon's UI looks and behaves consistently
- Minimap button for one-click access to the hub (can be hidden if you prefer the slash command)

## Chat Commands
- `/daseeki` or `/das` — toggle the options hub open/closed
- `/daseeki <section>` — jump straight to a specific addon's section (e.g. `/daseeki bufftracker`), once that addon is installed and registered
- `/daseeki minimap` or `/daseeki mm` — show/hide the minimap button

## Requires
Nothing — Core itself has no dependencies. It's the foundation the rest of the suite (Bags, Buff Tracker, Armory, Raid Mechanics, Raid Prep, Nexus, Conduit) plugs into. Note: **Daseeki Bags 2.0+ requires Core**; the others work without it but lose the unified hub and theming. Install Core first.

DISCLAIMER: I originally developed these addons for my own personal use, and am listing them on CurseForge to allow some friends to test/report bugs. The 'Daseeki' suite of addons is still very much a WIP, so please keep that in mind when downloading.
