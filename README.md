# Carry Farm Coach

Carry Farm Coach is a visual farming-route assistant for Dota 2 on the UCZone/Umbrella scripting platform. It recommends where to farm next and draws a short route on the game world. It does not move the hero or cast abilities for you.

This is an early Luna-only baseline. The current version favors nearby, reachable farm; estimates travel and clear time; lets visible lane creeps decay while you travel; keeps the camp you are actively clearing as the first step; and applies a basic penalty to camps on the enemy side of the map.

## Current status

- Supported hero: Luna
- Mode: visual advice only
- Route length: 2 to 4 steps
- Data: visible lane waves and neutral-camp information available through the Umbrella libraries
- Safety model: basic map-side risk only; enemy and ally presence are planned later

This project is still being tested. Treat every recommendation as advice, especially around dangerous areas and fog.

## Files

- `CarryFarmCoach.lua` — UCZone entry script, menu, data collection, diagnostics, and drawing
- `lib/carry_farm_coach.lua` — route scoring and planning logic
- `tools/test_carry_farm_coach.lua` — planner behavior tests
- `tools/test_carry_farm_coach_compat.lua` — compatibility checks
- `TODO.md` — known limitations and planned work

## Requirements

- UCZone API v2.0
- A current Umbrella installation
- These Umbrella libraries in `scripts/lib`: `map.lua`, `map_data.lua`, `farm.lua`, `lane.lua`, `draw.lua`, and `route.lua`

The shared Umbrella libraries are intentionally not copied into this repository. Get the current versions from their original maintainer instead of using stale duplicates.

The shared route planner must support the optional `distance_fn` route option in both `lib/lane.lua` and `lib/route.lua`. Older copies still generate candidates with straight-line distance, even though Carry Farm Coach validates the result with real path distance afterward.

## Installation

1. Download the repository using **Code → Download ZIP**, then extract it.
2. Copy `CarryFarmCoach.lua` into your Umbrella `scripts` folder.
3. Copy `lib/carry_farm_coach.lua` into Umbrella's `scripts/lib` folder.
4. Confirm the required shared libraries listed above are already in `scripts/lib`.
5. Reload scripts in UCZone or restart Dota 2.
6. Open the script menu under `Carry Farm Coach` and enable it while playing Luna.

For the default Windows layout, the result should look like this:

```text
Umbrella/
└── scripts/
    ├── CarryFarmCoach.lua
    └── lib/
        ├── carry_farm_coach.lua
        ├── draw.lua
        ├── farm.lua
        ├── lane.lua
        ├── map.lua
        ├── map_data.lua
        └── route.lua
```

## Testing and bug reports

Enable `Diagnostics` in the script menu when reproducing a bad recommendation. A useful report includes:

- a screenshot showing Luna, the suggested route, and nearby farm;
- the matching `[CarryFarmCoach] replan` lines;
- game time and which side Luna is playing;
- what you expected the route to choose instead.

Please do not report a route decision from the screenshot alone—the diagnostic line contains the travel, timing, risk, and route values needed to explain it.

## Roadmap

The immediate goal is a reliable simple route coach. Enemy-location risk, ally control, improved lane prediction, more carry heroes, and post-game coaching remain later work. See [TODO.md](TODO.md) for the working list.

## UCZone documentation

[UCZone API v2.0 documentation](https://uczone.gitbook.io/api-v2.0)

## License

Released under the [MIT License](LICENSE).
