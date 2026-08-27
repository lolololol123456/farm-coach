# CarryFarmCoach backlog

## Active baseline

- [x] Add structural camp risk using `Farm.StructuralRisk` and team fountains.
- [x] Penalize enemy-half camps without reading hero presence.
- [x] Show structural risk in diagnostics so live decisions can be verified.
- [x] Add a menu slider for enemy-side risk strength.

## Risk upgrades after baseline validation

- [ ] Reduce enemy-side risk when Luna and multiple allied heroes already control that area.
- [ ] Add visible-enemy proximity risk without using missing-enemy guesses.
- [ ] Add short-lived recent-enemy memory so a hero entering fog does not instantly make a camp safe.
- [ ] Add tower and outpost control to structural risk.
- [ ] Add a separate lane-wave safety model; do not reuse camp risk blindly.
- [ ] Log each risk component independently: structural, enemy presence, ally control, and objectives.

## Routing quality

- [x] Keep an actively cleared live camp as route step one until it is empty or Luna leaves.
- [x] Use real walking distance during candidate generation and final route scoring.
- [ ] Draw the actual `GridNav.BuildPath` polyline instead of a straight visual connector.
- [ ] Log whether each distance used pathfinding or straight-line fallback.
- [ ] Validate the three-second path cache against destroyed and temporary trees.
- [ ] Improve candidate diagnostics to show the winning route and closest rejected alternative.
- [ ] Validate the 12-second maximum-leg default in real matches.
- [ ] Validate tempo scoring against nearby small or large camp versus distant ancient decisions.
- [ ] Revisit the 60-second route horizon after enough real route samples exist.

## Wave model

- [ ] Calibrate visible-wave decay against creep deaths observed during travel.
- [ ] Learn wave clear time only after a reliable ownership detector exists.
- [ ] Keep fog-predicted waves diagnostic-only until a trustworthy source is available.
- [ ] Revisit Umbrella native Creep Wave integration only if its Lua interface is documented.

## Hero coverage

- [ ] Validate Luna as the ranged baseline in normal matches.
- [ ] Add a second ranged carry using the same advisor contract.
- [ ] Design melee-specific engagement and clear-time estimates separately.

## Later coaching features

- [ ] Add fight-proximity advice without issuing orders.
- [ ] Add lane-pressure and objective timing context.
- [ ] Add an optional post-game evaluator only after live route advice is reliable.
