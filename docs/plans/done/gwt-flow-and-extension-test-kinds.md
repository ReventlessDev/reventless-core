# GWT Flow + Extension Test Kinds — Cross-Slice and Cross-Plugin GWT

## Status: DONE (2026-05-21)

- **Phase 0 — DONE.** `Outcome.PublishedActionsMismatch` added (+ `kindName`/`format`/`toJson`,
  Hint, `FormatterHuman`/`Tap`/`VsCode`/`Json` cases; JSON `schemaVersion` bumped to `1.1.0`).
  Shared `reventless-gwt/src/StubRuntime.res` (queryEngine, schedule create/delete, meta,
  pluginDefinition). gwt builds zero-warning; 41 existing tests green.
- **Phase 1 — DONE.** `Delegate_GWT.res` (`Make` core + `FromExtensionPoint` / `FromExtension`).
  PPX `Delegate` kind wired (`Util.dsl_kind_of_segment` explicit `ExtensionPoint`/`Extension`/
  `Delegate` handling — deliberately NOT via `slice_base_to_kind` to keep them out of
  `known_slice_bases`; `GwtInference.functor_name_for` + `.Mapping` functor-arg for the
  Extension flavour). macOS PPX binary rebuilt; **Linux binary deferred to a single rebuild
  after the Phase 2 PPX edits**. Worked example `tests/DelegateGwtTest.res` (6 tests) + hybrid
  examples (catalog/ordering ExtensionPoint + Extension `_GWT.res`, 8 tests). jest + CLI runner
  green. NOTE: no `run.sh` PPX fixture added — the repo verifies `@@reventless.gwt` injection via
  example builds (run.sh has no GWT fixtures), so the hybrid `_GWT.res` files are that test.
- **Phase 2 — DONE.** `Flow_GWT.res` with per-step functors `CommandStep` / `AutomationStep` /
  `ViewStep` / `OutboundStep` over one JSON-erased log, with per-command-step DCB tag filtering
  (mirrors the in-memory log's `matchesQuery` + `buildQueryFromCommand`) and tolerant cross-slice
  decode via `DcbDecode.makeDecoder`. PPX `Flow` kind injects **only** `open ReventlessGwt.Flow_GWT`
  (no `include`, no Spec resolution) — verified in the compiled output. Worked example
  `tests/FlowGwtTest.res` (5 tests, incl. DCB tag isolation) + hybrid Tier-1
  `ordering/tests/Flow/OrderingFlow_GWT.res` (2 tests). macOS PPX binary rebuilt.
- **Phase 3 — DONE.** `Flow_GWT` boundary steps `ExtensionPointStep` (`whenPublishedThrough` /
  `thenPublicEvent(s)`, one-to-many fan-out) and `ExtensionStep` (`whenExtensionReacts` /
  `thenIssuesCommand(s)`), handing the public EP events from one plugin to the next via `lastPublic`.
  Self-contained two-plugin fixture `tests/FlowCrossPluginGwtTest.res` (3 tests: Tier-2 forward,
  Tier-2 negative, Tier-3 fan-out). Hybrid showcase on the REAL plugins lives in
  `examples/online-shop-hybrid/platform-in-memory/tests/Flow/HybridFlow_GWT.res` (3 tests) — placed
  there because plugin isolation forbids a single plugin package from importing the other's slices;
  the platform package (which composes both) gained minimal test infra (tests/ source dir,
  `reventless-gwt` + `rescript-jest` deps, jest field, `__mocks__/emptyModule.js`). **Both PPX
  binaries (osx-x64 + linux via Docker) rebuilt to the final PPX.**
- **Phase 4 — DONE.** `Query_GWT.MakeResolver(Primary, Target)` (`givenStores` / `whenResolve` /
  `whenResolveMany` / `thenResolved(Many)`) for cross-spec `@resolves` / `@resolvesMany` joins over a
  JSON-erased target store, validating the resolver is declared in `Primary.config`. Worked example
  `tests/QueryResolverGwtTest.res` (3 tests; no hybrid application — no example read model declares
  `@resolves`). `OutboundTranslation_GWT` now tracks a REAL retry counter: `attempt.retries` +
  `whenTranslateRetrying(~maxRetries)`; `thenRetryRecorded(n)` asserts the actual count (was
  intent-only). Worked example extended in `tests/OutboundTranslationGwtTest.res` (2 new tests).
- **Verification.** gwt 60 jest / 53 CLI; catalog 49; ordering 55; platform-in-memory 3; PPX 195 —
  all green, zero warnings. Both PPX binaries rebuilt (Phase 4 touched no PPX).

## Source

Implements the opportunities in
[`docs/analysis/gwt-test-type-coverage-and-opportunities.md`](../analysis/gwt-test-type-coverage-and-opportunities.md).
Builds on the shipped GWT substrate from
[`docs/plans/done/reventless-gwt.md`](done/reventless-gwt.md) (Stages 1–12).

## Goal

Add the three GWT kinds the coverage analysis identifies as missing, in dependency order:

1. **`Delegate_GWT`** — a GWT kind for ExtensionPoint mappings and Extension delegates
   (the single-component §3.1/§3.2 gap; the cross-plugin *boundary primitive*).
2. **`Flow_GWT` (single-plugin)** — a pure cross-slice DSL threading one event log through
   a chain of slices (Tier 1 of the analysis §6.2).
3. **`Flow_GWT` (cross-plugin)** — boundary steps that continue a flow from one plugin into
   the next through `Delegate_GWT` invocation (Tiers 2–3).
4. **(Optional) Smaller refinements** — `Query_GWT` cross-spec resolvers and the
   `OutboundTranslation_GWT` retry counter (analysis §7).

## Why this matters

Every GWT test today verifies one tile of an Event Modeling board in isolation. Nothing
verifies the tiles connect, and the cross-plugin seam (ExtensionPoint mapping + Extension
delegate) has zero GWT coverage. Connected flows are testable only via imperative,
bus-based integration tests that the GWT runner cannot discover and an LLM cannot derive
from a diagram. These kinds close that gap inside the existing `Outcome` + CLI substrate.

## Discovery facts that shape the plan

(From a full read of `reventless-gwt/src/`, `packages/reventless-ppx/src/ppx/`, and the
`online-shop-hybrid` runtime shapes.)

- **The runner is kind-agnostic.** [`Discovery.res`](../../reventless/reventless-gwt/src/Discovery.res)
  matches `*_GWT.res.mjs` / `*GwtTest.res.mjs` / `*Gwt.res.mjs` by filename and
  dynamic-imports them; [`Loader.res`](../../reventless/reventless-gwt/src/Loader.res) just
  runs whatever `describe`/`test` the file registers via
  [`Collector`](../../reventless/reventless-gwt/src/Collector.res). **New kinds need no
  runner changes** — they only must (a) call `JestBind.describe`/`test`, (b) return
  `Outcome.outcome` from every `then*`, (c) compile to a `*_GWT.res.mjs`.
- **Outcome algebra** ([`Outcome.res`](../../reventless/reventless-gwt/src/Outcome.res)):
  `type outcome = result<unit, mismatch>`; `let pass = Ok()`; `let fail = m => Error(m)`.
  `mismatch` is a closed variant (9 cases today: `EventsMismatch`, `ErrorMismatch`,
  `StateMismatch`, `NoEventExpected`, `TodoMismatch`, `AppendConditionMismatch`,
  `TranslateError`, `QueryRowsMismatch`, `Throw`). Adding a kind that asserts a *new* shape
  requires a new constructor here plus cases in `Outcome.kindName/format/toJson` and
  [`Hint.forMismatch`](../../reventless/reventless-gwt/src/Hint.res).
- **DSL shape to mirror**: [`Mapping_GWT.res`](../../reventless/reventless-gwt/src/Mapping_GWT.res)
  is the closest analog — async, threads a `scenario` tuple through a pipe-first chain,
  re-exports `describe = JestBind.describe` and `test = JestBind.testPromise(~slice=…)`,
  uses a **stubbed `Reventless.QueryEngine.operations`**, and encodes via `Message.encode`.
  `From*` adapter functors (as in `Mapping_GWT.FromBehavior`/`FromStateChangeSlice` and
  `Query_GWT.FromReadModel`/`FromStateViewSlice`) are the established way to serve two
  patterns from one core — the model for `Delegate_GWT.FromExtensionPoint`/`FromExtension`.
- **PPX kind selection** lives in two files:
  [`Util.ml`](../../packages/reventless-ppx/src/ppx/Util.ml) (`slice_base_to_kind` table +
  `dsl_kind_of_segment` substring fallback + `derive_gwt_kind`) and
  [`GwtInference.ml`](../../packages/reventless-ppx/src/ppx/GwtInference.ml)
  (`is_two_arg_kind`, `functor_name_for`, `kinds_list_for_error`, payload parsing,
  `gen_include_one`/`gen_include_two`, multi-/single-open injection). Every new kind touches
  this enumerated set of sites.
- **The `Flow` kind breaks single-Spec PPX assumptions.** All current kinds inject
  `include <Kind>_GWT.Make(<Spec>)` from one (or two) modules resolved from the filename
  stem or the first top-level module(s). A flow references *several* slice modules and has
  no single Spec. Plan: the `Flow` kind injects **only** `open ReventlessGwt.Flow_GWT`
  (no `include`, no functor application) — a genuinely new PPX path.
- **Runtime functions the DSLs call are all pure** (translate is `async`):
  - EP mapping: `mapOutgoingEvent: option<(JSON.t, Schedule.create, Schedule.delete, QueryEngine.operations) => array<eventAction>>` with `PublishEvent(id, event)` / `PublishEventAsync` / `Call`; array fan-out is plain `Array.map` (see `Orders_ExtensionPointMapping.res`).
  - Extension delegate: `mapIncomingEvent: (id, event, meta, pluginDefinition, QueryEngine.operations) => array<incomingCommandAction>` with `PublishStateChangeSliceCommand(cmd)` / `PublishAggregateCommand(id, cmd)` / `PublishExtensionPointCommand(id, cmd)` / `Call`.
  - StateChangeSlice: `Behavior.decide(state, command) => result<array<event>, error>`, `Behavior.evolve(state, consumedEvent) => state`, `initialState`.
  - Projection: `project(consumedEvent) => array<Projection.action<string, state>>` (`Set`/`Update`/`Delete`).
  - Automation: `collect(event, ctx) => array<(string, todoItem)>`, `resolve(event) => option<string>`, `process(id, todoItem) => option<(string, command)>`.
  - OutboundTranslation: `collect(event) => array<(string, outboundItem)>`, `translate(id, outboundItem) => promise<result<option<inboundCommand>, string>>`.
  - DCB filtering: `DcbTag.buildQueryFromCommand(~eventTypes, ~schema, ~value)`, `extractTags`/`extractTagsExpanded`, `extractAllVariantNames` — replicate per-spec filtering when a flow crosses DCB slices.

---

## Phase 0 — Shared Outcome + stub scaffolding

**Goal:** the cross-cutting pieces Phases 1–3 reuse.

1. **New `Outcome.mismatch` constructors** in
   [`Outcome.res`](../../reventless/reventless-gwt/src/Outcome.res):
   - `PublishedActionsMismatch({expected: array<JSON.t>, actual: array<JSON.t>})` — for
     `Delegate_GWT` and the flow boundary steps (asserts the set of published
     events/commands, supporting one-to-many fan-out).
   - Reuse `EventsMismatch` / `StateMismatch` / `ErrorMismatch` for flow command/view/error
     steps — no new constructor needed for those.
   Add matching cases to `kindName`, `format`, `toJson`, and bump the JSON `schemaVersion`
   if the runner's output schema is versioned (check `FormatterJson.res`).
2. **Hint cases** in [`Hint.res`](../../reventless/reventless-gwt/src/Hint.res) for
   `PublishedActionsMismatch`.
3. **Shared test stubs** (new `reventless-gwt/src/StubRuntime.res`, or extend the existing
   stub Mapping_GWT uses): a no-op `QueryEngine.operations`, `Schedule.create`/`delete`
   stubs, a default `Message.meta`, and a default `Plugin.pluginDefinition`. EP/Extension
   mappings receive these as inert arguments. Confirm whether `Mapping_GWT` already exposes
   a reusable QueryEngine stub and lift it here rather than duplicating.

**Verify:** `reventless-gwt` builds with zero warnings; existing GWT suites still green
(`pnpm test` + `reventless-gwt run tests/`).

---

## Phase 1 — `Delegate_GWT` (ExtensionPoint + Extension boundary primitive)

**Goal:** GWT-test an EP mapping or an Extension delegate as a pure input→published-actions
translation; this is also the boundary step the cross-plugin flow reuses.

### New file: `reventless-gwt/src/Delegate_GWT.res`

- A core `Make(D: Delegate)` functor where `Delegate` abstracts "given an inbound message,
  produce published actions": exposes the inbound event type + schema, the published-action
  encoders, and the underlying mapping function.
- Two adapter functors mirroring `Query_GWT`/`Mapping_GWT`:
  - `FromExtensionPoint(M)` — wraps an EP mapping module: drives `M.mapOutgoingEvent`
    (handling the `option`), feeding `StubRuntime` schedule/queryEngine; published actions
    are `PublishEvent(id, event)` etc.
  - `FromExtension(M)` — wraps an Extension `Mapping` module: drives `M.mapIncomingEvent`
    with `StubRuntime` meta/pluginDefinition/queryEngine; published actions are
    `PublishStateChangeSliceCommand(cmd)` / `PublishAggregateCommand(id, cmd)` / etc.
- DSL combinators (sync; both adapters share the surface):
  - `whenInboundEvent(event) => actions`
  - `thenPublishesEvent(actions, id, event)` / `thenPublishesEvents(actions, [(id, event)])`
  - `thenPublishesCommand(actions, target, cmd)` / `thenPublishesCommands(actions, […])`
  - `thenPublishesNothing(actions)`
  - `describe`/`test` re-exported from `JestBind` with `~slice` = the delegate name.
  - Fan-out (one inbound → N published) is naturally covered by the `*Events`/`*Commands`
    plural assertions and `PublishedActionsMismatch`.

### PPX wiring (teach the kind)

Edit sites (all enumerated by discovery):

- [`Util.ml`](../../packages/reventless-ppx/src/ppx/Util.ml):
  - `slice_base_to_kind`: add `("Extension", "Delegate")` and `("ExtensionPoint", "Delegate")`.
  - `dsl_kind_of_segment`: add substring fallbacks for `ExtensionPoint` (check **before**
    `Extension`, since `ExtensionPoint` contains `Extension`) and `Extension`.
- [`GwtInference.ml`](../../packages/reventless-ppx/src/ppx/GwtInference.ml):
  - `functor_name_for`: when `kind = "Delegate"`, pick `FromExtensionPoint` if the file is in
    an `ExtensionPoint/` folder (or stem contains `ExtensionPointMapping`), else `FromExtension`
    — exactly mirroring the existing `MakeFromAggregate`-vs-`Make` switch for Behavior.
  - Keep `Delegate` one-arg (`is_two_arg_kind` unchanged). The single functor arg is the EP
    mapping module / Extension `Mapping` module, resolved from the filename stem or first
    top-level module like every other one-arg kind.
  - `kinds_list_for_error`: mention `ExtensionPoint` / `Extension`.

### PPX binary rebuild

Per repo convention (MEMORY): `pnpm run build:ppx` (macOS) **and** the Linux Docker build;
commit both `ppx-osx.exe` and `ppx-linux.exe`.

### Tests

- Worked example in `reventless-gwt/tests/` (a minimal EP + Extension fixture) exercising
  fan-out and the From* split, plus a PPX fixture under `packages/reventless-ppx/test/`
  asserting the injected `include … Delegate_GWT.FromExtensionPoint(…)` / `FromExtension(…)`.
- Apply to the hybrid example: `Products_ExtensionPointMapping_GWT.res`,
  `Orders_ExtensionPointMapping_GWT.res` (asserts the `OrderPlaced → ItemOrdered ×N`
  fan-out), `Products_Extension_GWT.res`, `Orders_Extension_GWT.res`.

**Verify:** zero warnings; new + existing suites green via both jest and the CLI runner.

---

## Phase 2 — `Flow_GWT` (single-plugin, Tier 1)

**Goal:** thread one JSON-erased event log through a chain of slices in a plugin and assert
the command, downstream automation command, read-model state, and outbound effect — one
declarative chain.

### New file: `reventless-gwt/src/Flow_GWT.res`

- **Shared log**: `type log = array<(string, JSON.t)>` (typeName, encoded event), ordered,
  matching the `Message.encode` / `Message.splitMessage` precedent Mapping_GWT uses. Async
  overall (projections and translate are async) → `then*` return `promise<Outcome.outcome>`.
- **Step API via per-step functors** (spike-validated — see "Spike outcome" below). Each
  test instantiates one step module per slice from its Spec + impl, then pipes `flow`
  through them. `when` is reserved in ReScript, so steps use `whenCommand`/`whenReacts`/…,
  never bare `when`:
  - `module Place = Flow_GWT.CommandStep(PlaceOrder, PlaceOrder_Behavior)` (the functor takes
    Spec + impl directly and builds the structural slice internally — no hand-written adapter).
  - `givenEvents(events) => flow`
  - `Place.whenCommand(flow, command) => flow` — filters the log via
    `DcbTag.buildQueryFromCommand`, folds `evolve`, runs `decide`, appends encoded events.
  - `Place.thenEvents(flow, [event])` / `Place.thenError(flow, error)` (reuse `EventsMismatch`/`ErrorMismatch`).
  - `Auto.whenReacts(flow) => flow` (from `AutomationStep(Spec, Automation)`) — runs
    `collect`/`process`; `Ship.thenIssuesCommand(flow, command)` asserts the emitted command.
  - `Orders.thenViewState(flow, id, state)` (from `ViewStep(Spec, Projection)`) — folds `project`, asserts state (`StateMismatch`).
  - `Confirm.thenOutbound(flow, expected)` (from `OutboundStep(Spec, Translation)`) — runs `collect`/`translate` (async), asserts the effect.
  - `describe`/`test(~timeout)` re-exported from `JestBind` (`testPromise`).
  The pipe threads `flow` across the heterogeneous per-slice step modules — each step
  takes and returns `flow`, so a multi-slice chain reads top-to-bottom in one expression.

#### Spike outcome (2026-05-21)

A throwaway spike (now removed) validated open decision #2 against the real hybrid
`PlaceOrder` slice. Both candidate forms **typecheck and compile**:

- **Per-step functor** (`CommandStep(Spec, Behavior)`) — chosen. The slice's Spec+Behavior
  pack into a structural `CommandSlice` module type; the JSON-erased log threads via
  `S.parseJsonOrThrow` / `S.reverseConvertToJsonOrThrow` (the package's existing erasure).
  Call site is terse: instantiate once, then `flow->Place.whenCommand(cmd)->Place.thenEvents([…])`.
- **First-class modules + locally-abstract types** (`whenCommand(flow, module(Slice with type … and …), cmd)`) — also works, but requires a verbose 5-line `with type … and …` annotation at *every* call site (or a one-time packed binding). Rejected on ergonomics.

Consequences folded into this plan: (a) `when` is reserved → method naming; (b) the step
functor takes Spec + impl, eliminating a hand-written adapter; (c) authors instantiate the
step modules explicitly, which **simplifies the PPX `Flow` kind** — see PPX wiring below.

### PPX wiring (the no-functor kind)

- `Util.ml`: `slice_base_to_kind` add `("Flow", "Flow")`; `dsl_kind_of_segment` add `Flow`
  substring fallback.
- `GwtInference.ml`: add a `Flow` branch that injects **only** `open ReventlessGwt.Flow_GWT`
  (and any auto-`open` of a sibling `_Fixtures.res`) — **no `include`, no functor
  application, no Spec resolution**. This is the new PPX path; guard the existing
  Spec-resolution/`gen_include_*` logic so `Flow` skips it. `kinds_list_for_error` mentions `Flow`.
  The spike confirms this is **sufficient**: because authors instantiate the per-slice step
  functors themselves (`module Place = Flow_GWT.CommandStep(PlaceOrder, PlaceOrder_Behavior)`),
  the PPX never needs the composite-Spec payload, multi-`open`, or "first N modules" logic
  the original design feared — the open-only injection is the whole job.
- Rebuild both PPX binaries; add a PPX test fixture asserting the `Flow` file gets only the
  `open` (no `include`).

### Tests

- `reventless-gwt/tests/Flow/` self-contained single-plugin fixture.
- Hybrid Ordering Tier-1 flow: `PlaceOrder → OrderPlaced` → `AutoShipOrder` issues
  `ShipOrder` → `OrderShipped` → `Orders` view = Shipped → `SendOrderConfirmation` fired.

**Verify:** zero warnings; jest + CLI runner green.

---

## Phase 3 — `Flow_GWT` cross-plugin (Tiers 2–3)

**Goal:** continue a flow across a plugin boundary through the `Delegate_GWT` invocation
built in Phase 1.

### Extend `Flow_GWT.res` with boundary steps

- `whenPublishedThrough(flow, module(EPMapping)) => flow` — runs `mapOutgoingEvent` over the
  new events (reusing `Delegate_GWT.FromExtensionPoint` internals), appending the public EP
  events to the log; handles **one-to-many fan-out** (`OrderPlaced{productIds:[…]}` → N×`ItemOrdered`).
- `thenPublicEvent(flow, event)` / `thenPublicEvents(flow, [event])`.
- `whenExtensionReacts(flow, module(ExtMapping)) => flow` — runs `mapIncomingEvent`
  (reusing `Delegate_GWT.FromExtension`), surfacing the issued commands.
- `thenIssuesCommand(flow, module(Slice), command)` (shared with Phase 2).
- **Two-plugin heterogeneous log + per-plugin DCB filtering**: the log already spans both
  plugins' encoded events; each downstream command step filters by its own spec's tags
  (`DcbTag`) exactly as the runtime routes — no new mechanism, just ensure filtering is
  per-step-spec, not global.
- **Plugin isolation**: boundary steps reference EP types from the *spec packages*
  (`catalog-spec`/`ordering-spec`), never the other plugin's source — the test mirrors
  production wiring.

### Tests

- Self-contained two-"plugin" fixture in `reventless-gwt/tests/Flow/` (so the framework
  package's own CI proves cross-plugin without depending on examples).
- Hybrid showcase: Tier-2 forward (`AddProduct` in Catalog → EP → sync → `PlaceOrder`
  *succeeds only because of the sync*) and Tier-3 round-trip demand loop (`OrderPlaced →
  ItemOrdered ×N → RecordDemand → ProductDemand count`, with the cancel mirror).

**Verify:** zero warnings; jest + CLI runner green; the hybrid suite demonstrates the
"two plugins agree about reality" property no single-component test can assert.

---

## Phase 4 — Smaller refinements (optional, analysis §7)

- **`Query_GWT` cross-spec resolvers**: `Query_GWT.MakeResolver(From, Target)` (or `Make2`)
  for `whenResolve`/`whenResolveMany` over foreign rows (JSON-erased store).
- **`OutboundTranslation_GWT.thenRetryRecorded(n)`**: track a real retry counter in the
  harness's scenario state instead of documenting intent only.

---

## Out of scope

- **Bus-backed `Scenario_GWT`** (analysis §5.2 flavor B): wrapping the in-memory bus in GWT
  largely re-expresses existing integration tests. Revisit only if the pure `Flow_GWT`
  proves insufficient.
- **AI generation of flow suites from Event Modeling diagrams**: a separate effort (and the
  highest-leverage follow-up); this plan ships the runnable substrate it would target.
- **Task GWT** (analysis §3.3): infra-bound, left to integration tests.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| The `Flow` no-functor PPX path destabilises kind resolution | Guard the new branch so only `kind = "Flow"` skips Spec resolution; cover with a dedicated PPX fixture. |
| ~~First-class slice modules fight ReScript's type system in `Flow_GWT`~~ | **Resolved by spike (2026-05-21):** both FCM and per-step functors compile against the real hybrid `PlaceOrder` slice; per-step functors chosen for terser call sites. |
| PPX Linux binary drift breaks CI | Rebuild via Docker and commit both binaries every phase that edits the PPX (MEMORY convention). |
| New `Outcome` constructor breaks the runner's output schema | Add `kindName`/`format`/`toJson`/Hint cases together; bump `schemaVersion` if versioned. |
| Cross-plugin fan-out mis-asserted (set vs. ordered) | `PublishedActionsMismatch` compares as a set where order is non-deterministic; plural assertions document multiplicity. |
| DCB tag filtering applied globally instead of per-spec | Each command/boundary step filters by *its* spec's schema (`DcbTag.buildQueryFromCommand`), never the whole log. |

## Open decisions (resolve during implementation)

1. **Kind name for EP/Extension**: `Delegate_GWT` (recommended — both EP mappings and
   Extension delegates are `Delegate` modules in repo/PPX terminology, and `Mapping_GWT` is
   already taken by event mappings) vs. a folder-matching `ExtensionPoint_GWT`/`Extension_GWT`
   pair. Confirm before creating files (naming-collision check per repo convention).
2. ~~**`Flow_GWT` step ergonomics**: first-class modules vs. per-step functors~~ —
   **RESOLVED (spike 2026-05-21): per-step functors** `CommandStep(Spec, Behavior)` etc.
   (see Phase 2 "Spike outcome"). Both compiled against the real hybrid slice; functors win
   on call-site ergonomics.
3. **Flow test folder name**: `Flow/` vs. `Scenario/` for the PPX kind segment.

## Dependencies and ordering

Phase 0 → Phase 1 and Phase 2 are independent (either order); Phase 3 depends on **both**
1 and 2; Phase 4 is independent and last. The hybrid example
(`examples/online-shop-hybrid`) is the worked-example suite throughout.

## References

- Analysis: [`docs/analysis/gwt-test-type-coverage-and-opportunities.md`](../analysis/gwt-test-type-coverage-and-opportunities.md)
- Substrate rollout: [`docs/plans/done/reventless-gwt.md`](done/reventless-gwt.md)
- Design rationale: [`docs/analysis/given-when-then-specifications.md`](../analysis/given-when-then-specifications.md)
- PPX kind selection: [`packages/reventless-ppx/src/ppx/Util.ml`](../../packages/reventless-ppx/src/ppx/Util.ml), [`GwtInference.ml`](../../packages/reventless-ppx/src/ppx/GwtInference.ml)
- DSL analog: [`reventless/reventless-gwt/src/Mapping_GWT.res`](../../reventless/reventless-gwt/src/Mapping_GWT.res)
