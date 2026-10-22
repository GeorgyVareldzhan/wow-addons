# WoW Sirus Addons (3.3.5a)

A set of addons for the World of Warcraft 3.3.5a client (`## Interface: 30300`) on the Sirus server.
The repository lives directly in `Interface/AddOns`; only the folders listed below are tracked
(see `.gitignore`), everything else — stock `Blizzard_*` and other addons — is ignored.

The in-game UI of the custom addons is in Russian.

## Custom addons

### CraftPlan

Suggests what to craft from your bags right now to level professions as high as possible,
and where to get missing items (via Questie). A bar at the top of the screen, a "craft map" window
with "Plan" and "Scheme" tabs, plus fishing, sifting, trainer and vendor helpers.

Internals are documented (in Russian) in [`CraftPlan/SPEC.md`](CraftPlan/SPEC.md).

| Command | Action |
|---|---|
| `/cplan` | show/hide the bar |
| `/cplan min` | collapse/expand the bar |
| `/cplan map` | open/close the craft map |
| `/cplan need` | switch between the "Plan" and "Scheme" tabs |
| `/cplan clear` | remove trainer pins from the world map |
| `/cplan reset` | forget all recipes |
| `/fish` | pin the fishing panel (visible without a fishing pole) |
| `/fish loud` | loud bobber splash |
| `/fish reset` | clear the catch log |

Key bindings: Key Bindings → "CraftPlan (профессии)" — craft map, collapse bar,
cast, apply lure, swap fishing pole/weapon.

Optional dependencies: Questie-335, GatherMate.
Saved variables: `WhereToGetDB` (account), `CraftPlanDB` (per character).

### ProcAlert

Warrior helper: icons in the center of the screen — the bottom row shows procced abilities
(Overpower, Execute, Revenge, Bloodsurge, etc.), the top row shows regular attacks usable right now.
Takes stance, rage, cooldowns and range into account. An enemy list on the right shows your debuffs on them.

Main commands (`/pa` with no arguments prints full help):

| Command | Action |
|---|---|
| `/pa test` | show a preview |
| `/pa normal` | regular attacks row |
| `/pa def` | defensive abilities at low health |
| `/pa rush` | stance, Charge and Intercept on a hostile target |
| `/pa enemies` | enemy list on the right |
| `/pa hs <0-100>` / `/pa hs auto` | rage threshold for Heroic Strike |
| `/pa alert` | sound for important procs |
| `/pa sound` | sound |
| `/pa rage` | rage bar |
| `/pa keys` | key labels |
| `/pa gap <0-200>` | spacing between icons |

Saved variables: `ProcAlertDB`.

### MapPlus

Adds a "remove fog of war" checkbox under the world map — reveals areas you haven't explored yet.
Same via `/mapplus fog`. Saved variables: `MapPlusDB`.

## Third-party addons

Kept in the repository as is (possibly with local tweaks):

- **Questie-335** (v9.5.1) — quest helper, a Questie port for 3.3.5.
- **GatherMate** (v1.22) — herb, ore, gas and fishing nodes on the world map and minimap. GPL v2.

## Installation

Copy the folders you need into `World of Warcraft/Interface/AddOns/` and enable the addons
in the list on the character select screen. No build step — the client loads `.lua`/`.xml`
directly via `.toc` files. After editing code, `/reload` in game is enough.

## Adding a new addon to the repository

Since `.gitignore` excludes everything by default, a new folder has to be whitelisted explicitly:

```gitignore
!/NewAddon/
```
