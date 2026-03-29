# Streamline Component Functions: Unified Naming and Two-Function Pattern

Source: [streamlining-component-functions.md](../analysis/streamlining-component-functions.md)

This plan implements the unified naming proposal from the analysis. It's a **major breaking change** — since the project is pre-1.0 on alpha, a single breaking release is acceptable.

---

## Overview of Changes

### Naming Renames

| Component | Current | Proposed |
|---|---|---|
| Behavior | `init` + `apply` | `evolve` (with `initialState`) |
| Behavior | `create` + `execute` | `decide` (returns `result`) |
| Behavior | *(no initialState)* | `initialState: state` |
| StateChangeSlice | `decisionModel` | `state` |
| StateChangeSlice | `initialDecisionModel` | `initialState` |
| StateChangeSlice | `reduce` | `evolve` |
| ReadModel Projection | `map` | `project` |

### Signature Changes

| Component | Current Signature | Proposed Signature |
|---|---|---|
| Behavior `decide` | `create: (command, context, errorHandler) => array<event>` + `execute: (state, command, context, errorHandler) => array<event>` | `decide: (state, command) => result<array<event>, error>` |
| Behavior `evolve` | `init: event => state` + `apply: (state, event) => state` | `evolve: (state, event) => state` |
| StateViewSlice `project` | `(option<state>, DcbEventLogSpec.event) => array<action>` | `DcbEventLogSpec.event => array<action>` (drop unused `option<state>`) |

---

## Step 1: Rename StateChangeSlice spec (`decisionModel` → `state`, `reduce` → `evolve`, `initialDecisionModel` → `initialState`)

**Goal:** Align StateChangeSlice naming with the unified vocabulary. This is the simplest step — pure renames, no signature changes.

### Files to Change

**Spec definition:**
- `reventless/reventless-spec/src/components/StateChangeSlice.res` — rename `type decisionModel` → `type state`, `let initialDecisionModel` → `let initialState`, `let reduce` → `let evolve`

**Framework consumers:**
- `reventless/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res` — update `Spec.initialDecisionModel` → `Spec.initialState`, `Spec.reduce` → `Spec.evolve`
- `reventless/reventless-core/tests/dcb/DcbStateChangeSliceTest.res` — update test fixture specs

**Example StateChangeSlice specs (29 files across 3 example projects):**
- `examples/online-shop-dcb/catalog/src/Category/StateChangeSlice/*.res` (3 files)
- `examples/online-shop-dcb/catalog/src/Product/StateChangeSlice/*.res` (5 files)
- `examples/online-shop-dcb/ordering/src/CatalogProduct/StateChangeSlice/*.res` (1 file)
- `examples/online-shop-dcb/ordering/src/Customer/StateChangeSlice/*.res` (4 files)
- `examples/online-shop-dcb/ordering/src/Order/StateChangeSlice/*.res` (3 files)
- `examples/online-shop-hybrid/catalog/src/Product/StateChangeSlice/*.res` (4 files)
- `examples/online-shop-hybrid/catalog/src/ProductDemand/StateChangeSlice/*.res` (1 file)
- `examples/online-shop-hybrid/ordering/src/CatalogProduct/StateChangeSlice/*.res` (1 file)
- `examples/online-shop-hybrid/ordering/src/Order/StateChangeSlice/*.res` (3 files)

### Verification
- `npm run build` from root — zero warnings
- `npm run test` in `reventless/reventless-core/` and affected example packages

---

## Step 2: Rename ReadModel Projection `map` → `project`

**Goal:** Align ReadModel Projection naming with StateViewSlice.

### Files to Change

**Spec definition:**
- `reventless/reventless-spec/src/types/Projection.res` — rename `let map` → `let project` in `module type Mapping` and `Mapping.Make` functor

**Framework consumers:**
- `reventless/reventless-core/src/components/ReadModel/ReadModel_Callback.res` — update calls to `Mapping.map` → `Mapping.project`
- `reventless/reventless-core/tests/EventMappingTest.res` — if it references `map`

**Example Projection Mappings (9 files):**
- `examples/online-shop-aggregates/catalog/src/ReadModel/CategoriesProjections.res`
- `examples/online-shop-aggregates/catalog/src/ReadModel/ProductsProjections.res`
- `examples/online-shop-aggregates/catalog/src/ReadModel/ProductDemandProjections.res`
- `examples/online-shop-aggregates/ordering/src/ReadModel/AvailableProductsProjections.res`
- `examples/online-shop-aggregates/ordering/src/ReadModel/CustomersProjections.res`
- `examples/online-shop-aggregates/ordering/src/ReadModel/OrdersProjections.res`
- `examples/online-shop-aggregates/ordering/src/EventMappings/Order_EventMappings.res`
- `examples/online-shop-hybrid/catalog/src/Category/ReadModel/CategoriesProjections.res`
- `examples/online-shop-hybrid/ordering/src/Customer/ReadModel/CustomersProjections.res`

### Verification
- `npm run build` from root — zero warnings
- `npm run test` in `reventless/reventless-core/` and affected example packages

---

## Step 3: Simplify StateViewSlice `project` signature (drop `option<state>` parameter)

**Goal:** The `option<state>` parameter is always passed as `None` in both `StateViewSlice_Callback.res` and `StateViewSlice_Builder.res`. Remove it.

### Files to Change

**Spec definition:**
- `reventless/reventless-spec/src/components/StateViewSlice.res` — change `let project: (option<state>, DcbEventLogSpec.event) => array<...>` → `let project: DcbEventLogSpec.event => array<...>`

**Framework consumers:**
- `reventless/reventless-core/src/components/StateViewSlice/StateViewSlice_Callback.res` — change `Spec.project(None, event)` → `Spec.project(event)`
- `reventless/reventless-core/src/components/StateViewSlice/StateViewSlice_Builder.res` — change `Spec.project(None, json->...)` → `Spec.project(json->...)`

**Example StateViewSlice specs (10 files):**
- `examples/online-shop-dcb/catalog/src/Category/StateViewSlice/CategoriesView.res`
- `examples/online-shop-dcb/catalog/src/Product/StateViewSlice/ProductDemandView.res`
- `examples/online-shop-dcb/catalog/src/Product/StateViewSlice/ProductsView.res`
- `examples/online-shop-dcb/ordering/src/CatalogProduct/StateViewSlice/AvailableProductsView.res`
- `examples/online-shop-dcb/ordering/src/Customer/StateViewSlice/CustomersView.res`
- `examples/online-shop-dcb/ordering/src/Order/StateViewSlice/OrdersView.res`
- `examples/online-shop-hybrid/catalog/src/Product/StateViewSlice/ProductDemandView.res`
- `examples/online-shop-hybrid/catalog/src/Product/StateViewSlice/ProductsView.res`
- `examples/online-shop-hybrid/ordering/src/CatalogProduct/StateViewSlice/AvailableProductsView.res`
- `examples/online-shop-hybrid/ordering/src/Order/StateViewSlice/OrdersView.res`

### Verification
- `npm run build` from root — zero warnings
- `npm run test` in `reventless/reventless-core/` and affected example packages

---

## Step 4: Transform Aggregate Behavior from 4 functions to 2 + `initialState`

**Goal:** Replace `init`/`apply`/`create`/`execute` with `initialState`/`evolve`/`decide`. This is the largest and most impactful step.

### 4a: Update Behavior spec (`reventless-spec`)

**File:** `reventless/reventless-spec/src/types/Behavior.res`

Change `module type T` from:
```rescript
type state
let init: Spec.event => state
let apply: (state, Spec.event) => state
let create: (Spec.command, Message.context, Handler.errorHandler<...>) => array<Spec.event>
let execute: (state, Spec.command, Message.context, Handler.errorHandler<...>) => array<Spec.event>
```

To:
```rescript
type state
let initialState: state
let evolve: (state, Spec.event) => state
let decide: (state, Spec.command) => result<array<Spec.event>, Spec.error>
```

### 4b: Update Behavior type aliases (`reventless-core`)

**File:** `reventless/reventless-core/src/Behavior.res`

Replace type aliases:
- Remove `type init`, `type apply`, `type create`, `type execute`
- Add `type evolve<'state, 'event> = ('state, 'event) => 'state`
- Add `type decide<'state, 'command, 'event, 'error> = ('state, 'command) => result<array<'event>, 'error>`

### 4c: Rewrite `Aggregate_Callback.res`

**File:** `reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res`

Major changes:
1. **Remove `errorHandler`** — errors now come back as `result` from `Behavior.decide`
2. **Remove `apply'` helper** — state is always concrete, starts at `Behavior.initialState`
3. **Simplify `processCommand`** — call `Behavior.decide(state, command)`, match on `Ok`/`Error`
4. **Simplify `replayProcessAppend`** — replay uses `Array.reduce(Behavior.initialState, Behavior.evolve)` instead of `option<state>` + `apply'`
5. **Move error logging into framework** — on `Error(error)`, log and return `Ok([])`

Key transformation for `processCommand`:
```rescript
// Before: switch stateO { Some(state) => Behavior.execute(...) | None => Behavior.create(...) }
// After:
switch Behavior.decide(state, command'.command) {
| Ok(newEvents) =>
  let newState = newEvents->Array.reduce(state, Behavior.evolve)
  Effect.succeed(Ok((newState, Array.concat(events, [(newEvents, command'->updateMeta)]))))
| Error(error) =>
  let errorJson = error->Message.encode(Spec.errorSchema)->JSON.stringify
  Effect.logError(`Behavior error ${errorJson} in ${Spec.name}(${command'.id->Spec.Id.toString})`)
  ->Effect.map(_ => Ok((state, events)))
}
```

Key transformation for `replayProcessAppend`:
```rescript
// Before: Stream.runFold((None, 0), ((st, n), ev) => (apply'(st, ev), n + 1))
// After:  Stream.runFold((Behavior.initialState, 0), ((st, n), ev) => (Behavior.evolve(st, ev), n + 1))
```

### 4d: Update `BehaviorTest` functor (both copies)

**Files:**
- `reventless/reventless-core/tests/BehaviorTest.res`
- `reventless/reventless-in-memory/src/test/BehaviorTest.res`

Major changes:
1. **Remove `errorHandler`** — test captures errors from `result` return
2. **Remove `currentState` helper** — use `Array.reduce(Behavior.initialState, Behavior.evolve)`
3. **Rewrite `exec`** — call `Behavior.decide(state, command)`, capture `Error` in `errors` ref

```rescript
let exec = (history, _context, command): array<Spec.event> => {
  errors := []
  let state = history->Array.reduce(Behavior.initialState, (s, e) => Behavior.evolve(s, e))
  switch Behavior.decide(state, command) {
  | Ok(events) => events
  | Error(error) =>
    errors := [error]
    []
  }
}
```

The `exec` function no longer needs `context` — simplify `whenCmd` and `whenCmdWithId` accordingly. `whenCmdWithId` may need rethinking since context is no longer passed to decide. If no Behavior uses the ID in decide, `whenCmdWithId` can be removed or kept for compatibility with tests that check state for a specific aggregate ID.

### 4e: Update `PluginBehavior.res` (platform built-in)

**File:** `reventless/reventless-core/src/admin/PluginBehavior.res`

Transform from `init`/`apply`/`create`/`execute` to `initialState`/`evolve`/`decide`:
- Add `let initialState = NotConnected` (or appropriate initial variant)
- `let evolve = (state, event) => ...` (merge `init` + `apply`)
- `let decide = (state, command) => ...` (merge `create` + `execute`, return `result`)
- Remove `context` and `errorHandler` parameters

### 4f: Update all example Behavior implementations (8 files)

Each Behavior file must be transformed:

**online-shop-aggregates/catalog:**
- `CategoryBehavior.res` — state needs `NotCreated` variant added to `type state`
- `ProductBehavior.res` — same pattern
- `ProductDemandBehavior.res` — same pattern

**online-shop-aggregates/ordering:**
- `CatalogProductBehavior.res`
- `CustomerBehavior.res`
- `OrderBehavior.res`

**online-shop-hybrid:**
- `catalog/src/Category/Aggregate/CategoryBehavior.res`
- `ordering/src/Customer/Aggregate/CustomerBehavior.res`

**Pattern for each:** Add `NotCreated` to state type, add `initialState = NotCreated`, merge `init`+`apply` → `evolve`, merge `create`+`execute` → `decide` returning `result`.

### 4g: Update Behavior tests

**Files:**
- `reventless/reventless-core/tests/plugin/PluginBehaviorTest.res`
- `reventless/reventless-core/tests/aggregate/AggregateCallbackTest.res`
- All example test files using the BehaviorTest functor
- In-memory E2E tests (`reventless/reventless-in-memory/tests/components/AggregateE2ETest.res`)

### 4h: Remove `Handler.errorHandler` type if now unused

**Check:** `reventless/reventless-spec/src/types/Handler.res` — if `errorHandler` is only used by Behavior, remove it. Also check `Message.errorHandler` alias in `reventless-core`.

### Verification
- `npm run build` from root — zero warnings
- `npm run test` across all packages
- Verify all example apps build and their tests pass

---

## Step 5: Update documentation

### Files to Update
- `packages/doc/docs/reventless-components/aggregate.md` — update Behavior section with new signatures
- `packages/doc/docs/index.md` — if it references init/apply/create/execute
- `docs/guides/platform-and-plugin-guide.md` — update all Behavior code examples
- `reventless/reventless-spec/src/types/Behavior.res` — update TSDoc examples in the module type
- `reventless/reventless-spec/src/types/Projection.res` — update TSDoc examples
- `reventless/reventless-spec/src/components/StateChangeSlice.res` — update TSDoc comments
- `reventless/reventless-spec/src/components/StateViewSlice.res` — update TSDoc comments

---

## Step 6: Clean up — remove dead code

- Remove `Message.context` type if no longer used by any user-facing function (check if other components still need it)
- Remove `Handler.errorHandler` type alias if unused
- Remove `type init`, `type apply`, `type create`, `type execute` from `Behavior.res` core type aliases
- Remove any deprecated aliases or compatibility shims

---

## Open Questions (from analysis — resolve before or during implementation)

1. **`whenCmdWithId` in BehaviorTest:** Currently passes an ID via `context`. With context removed from `decide`, how should aggregate-ID-specific testing work? The ID is used by the framework (in `Aggregate_Callback` to group and replay), not by the Behavior itself. Consider removing `whenCmdWithId` or rethinking its purpose.

2. **Should `decide` in Aggregate Behavior return `result` or just `array<event>`?** The analysis recommends `result`. This aligns with StateChangeSlice. The framework handles error logging. Empty `Ok([])` means "command accepted, no events" (idempotent). `Error(...)` means "business rule violated."

3. **Should ReadModel Projection's `project` return a single action or an array?** The analysis suggests examining this for harmonization with StateViewSlice (which returns `array`). Deferring to a separate plan — keep `project` returning single `action` for now.

4. **`Message.context` — is it used elsewhere?** Check if `context` is used in SideEffect handlers, EventMapping, or other framework components before removing.
