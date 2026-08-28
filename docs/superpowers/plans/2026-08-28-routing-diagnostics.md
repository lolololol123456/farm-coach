# Routing Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add five high-value diagnostics that explain rejected camps, path calculations, route timing, route changes, and camp-state transitions without changing farming recommendations.

**Architecture:** Pure diagnostic records are produced by `lib/carry_farm_coach.lua`; engine-facing path and camp observations are captured in `CarryFarmCoach.lua`. Every replan receives a monotonic `plan_id`. Diagnostics are emitted only when the existing Diagnostics switch is enabled, while transition logs are deduplicated by stored signatures.

**Tech Stack:** Lua, UCZone callbacks, existing logger, existing Lua regression harness.

**Spec:** Approved in chat on 2026-08-28: implement the recommended rejection ledger, path provenance, route timeline, route-change explanation, and camp-state transitions.

## Global Constraints

- Do not change route selection, scoring weights, camp availability, or path results.
- Prefer existing shared libraries and pure helpers.
- Diagnostics must be disabled when the existing Diagnostics switch is off.
- Every emitted diagnostic row must include the same monotonic `plan_id` as its `replan` row.
- High-frequency snapshots may repeat once per replan; state and route transition logs emit only when their signature changes.
- Use test-first development and run the complete existing Lua suite before deployment.

---

### Task 1: Rejection ledger and plan identifiers

**Files:**
- Modify: `lib/carry_farm_coach.lua`
- Modify: `CarryFarmCoach.lua`
- Modify: `tools/test_carry_farm_coach.lua`
- Modify: `tools/test_active_camp_wiring.lua`

**Interfaces:**
- Produces: `plan.diagnostics.rejections`, an array of `{key, stage, reason}` records.
- Produces: log fields `plan_id=<number>` and event `candidate_rejections`.

- [ ] Add failing pure tests proving opportunities report `accepted`, `invalid_data`, `expired`, `pool_cap`, `leg_too_long`, `outside_horizon`, and `lost_on_score` without affecting the chosen route.
- [ ] Run `lua tools/test_carry_farm_coach.lua` and verify the new checks fail because rejection diagnostics are absent.
- [ ] Add a pure validation/classification ledger to `Coach.Plan`; preserve the existing candidate objects and return value.
- [ ] Add `State.plan_id`, increment it once per replan, and include it on `replan`, `camp_candidates`, `route_alternatives`, and `candidate_rejections`.
- [ ] Extend the callback integration test to require a matching `plan_id` and rejection event.
- [ ] Run coach and callback tests and verify they pass.

### Task 2: Pathfinding provenance

**Files:**
- Modify: `CarryFarmCoach.lua`
- Modify: `tools/test_active_camp_wiring.lua`

**Interfaces:**
- Produces: per-path record `{method, distance, cache, cache_age, fallback_reason, from_key, to_key}`.
- Produces: event `path_diagnostics` keyed by `plan_id`.

- [ ] Add a failing callback test for fresh `GridNav`, cache hit, and straight-line fallback records.
- [ ] Refactor `walk_distance(a,b)` into a behavior-preserving wrapper that records provenance while returning the same numeric distance.
- [ ] Record `method=gridnav` for valid paths, `method=straight_fallback` for missing/invalid paths, and cache hit age for reused entries.
- [ ] Deduplicate path records within one plan by endpoint cache key.
- [ ] Emit compact `path_diagnostics` only when Diagnostics is enabled.
- [ ] Run callback, path-distance, and compatibility tests.

### Task 3: Route-step timeline

**Files:**
- Modify: `lib/carry_farm_coach.lua`
- Modify: `CarryFarmCoach.lua`
- Modify: `tools/test_carry_farm_coach.lua`

**Interfaces:**
- Produces: `plan.timeline`, containing `{key, depart, arrive, wait, clear, finish, value_at_arrival}` per chosen step.
- Produces: event `route_timeline` keyed by `plan_id`.

- [ ] Add a failing pure test with one immediately available camp and one delayed target, asserting exact depart, arrive, wait, clear, and finish values.
- [ ] Extend `simulate` to copy its already-calculated timing values into diagnostic timeline rows without changing feasibility or utility.
- [ ] Preserve arrival-decayed wave value in `value_at_arrival`.
- [ ] Emit one compact `route_timeline` row for the chosen plan.
- [ ] Run the coach suite and verify existing plan outputs and all new timeline checks pass.

### Task 4: Route-change explanation

**Files:**
- Modify: `lib/carry_farm_coach.lua`
- Modify: `CarryFarmCoach.lua`
- Modify: `tools/test_carry_farm_coach.lua`
- Modify: `tools/test_active_camp_wiring.lua`

**Interfaces:**
- Produces: diagnostic comparison `{old_route, new_route, margin_pct, trigger, stability}`.
- Produces: transition-only event `route_change` keyed by `plan_id`.

- [ ] Add failing pure tests for unchanged route, stability-preserved route, invalidated old route, lower travel, higher confidence, expiring value, and score-margin replacement.
- [ ] Return the stability decision and winning comparison metrics from `Coach.Plan` without changing the existing stability gate.
- [ ] Store the last emitted route signature in runtime state.
- [ ] Emit `route_change` only when the displayed route sequence changes.
- [ ] Run coach and callback tests and confirm repeated identical replans produce no duplicate transition event.

### Task 5: Camp-state transitions

**Files:**
- Modify: `CarryFarmCoach.lua`
- Modify: `tools/test_active_camp_wiring.lua`

**Interfaces:**
- Produces: transition `{key, from, to, cause, box_count, nearest_count, live_count, cleared_until}`.
- Produces: transition-only event `camp_state_change` keyed by `plan_id`.

- [ ] Add a failing callback regression for `unknown -> live`, `live -> cleared`, and `cleared -> live` via nearest-neutral recovery.
- [ ] Store the previous compact camp state per key in `State` and reset it with match lifecycle state.
- [ ] Derive causes from existing observations: `box_neutral`, `nearest_neutral`, `visible_empty`, `cleared_latch`, `cached`, and `clock_estimate`.
- [ ] Emit only changed state signatures and include counts plus cleared expiry.
- [ ] Run callback and active-camp tests.

### Task 6: Release verification and deployment

**Files:**
- Modify: `README.md`
- Modify: `TODO.md`

**Interfaces:**
- Documents the diagnostic events and the three-line minimum bug report format.

- [ ] Document each event and state explicitly that diagnostics do not alter recommendations.
- [ ] Run coach, active-camp, wiring, route-distance, compatibility, repository-load, and Lua syntax tests.
- [ ] Run the full Umbrella shared-library suite and report any unrelated pre-existing failure separately.
- [ ] Copy only verified runtime files into `Umbrella/scripts` and `Umbrella/scripts/lib`.
- [ ] Verify source/live SHA-256 equality.
- [ ] Commit and push the exact tested version.
- [ ] In-game test one skipped-nearby-camp reproduction and collect matching `replan`, `candidate_rejections`, `path_diagnostics`, `route_timeline`, `route_change`, and `camp_state_change` rows.
