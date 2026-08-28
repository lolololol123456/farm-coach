# Carry Farm Coach

Carry Farm Coach is a visual farming-route assistant for Dota 2 on the UCZone/Umbrella scripting platform. It recommends where to farm next and draws a short route on the game world. It does not move the hero or cast abilities for you.

This is an early Luna-only baseline. The current version favors nearby, reachable farm; estimates travel and clear time; lets visible lane creeps decay while you travel; keeps the camp you are actively clearing as the first step; and applies a basic penalty to camps on the enemy side of the map.

## Current status

- Supported hero: Luna
- Mode: visual advice only
- Route length: 2 to 4 steps
- Data: visible lane waves and neutral-camp information available through the Umbrella libraries
- Safety model: basic map-side risk; nearby allies are used only to avoid misattributing their camp damage to Luna

This project is still being tested. Treat every recommendation as advice, especially around dangerous areas and fog.

## Files

- `CarryFarmCoach.lua` — UCZone entry script, menu, data collection, diagnostics, and drawing
- `lib/carry_farm_coach.lua` — route scoring and planning logic
- `lib/draw.lua` — shared world-to-screen and drawing helpers
- `lib/farm.lua` — shared farming valuation and risk helpers
- `lib/lane.lua` — shared lane intelligence and embedded route planner
- `lib/map.lua` — shared camp, neutral, and pathfinding helpers
- `lib/map_data.lua` — shared Dota map positions
- `lib/route.lua` — standalone shared route planner
- `tools/test_carry_farm_coach.lua` — planner behavior tests
- `tools/test_active_camp.lua` — active-camp ownership and release tests
- `tools/test_active_camp_wiring.lua` — callback integration test for active-camp route locking
- `tools/test_carry_farm_coach_compat.lua` — compatibility checks
- `tools/test_route_distance.lua` — verifies path-distance support in both route planners
- `tools/test_repository_load.lua` — verifies a fresh checkout has every required Lua dependency
- `TODO.md` — known limitations and planned work

## Requirements

- UCZone API v2.0
- A current Umbrella installation
- No separate library download is required; every Lua dependency used by Carry Farm Coach is included in this repository.

## Installation

1. Download the repository using **Code → Download ZIP**, then extract it.
2. Copy `CarryFarmCoach.lua` into your Umbrella `scripts` folder.
3. Copy the entire contents of this repository's `lib` folder into Umbrella's `scripts/lib` folder. Replace existing files when prompted.
4. Reload scripts in UCZone or restart Dota 2.
5. Open the script menu under `Carry Farm Coach` and enable it while playing Luna.

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

Carry Farm Coach is released under the [MIT License](LICENSE). The included shared libraries retain their original authorship; see [THIRD_PARTY_NOTICE.md](THIRD_PARTY_NOTICE.md).
