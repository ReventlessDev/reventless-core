# GWT Test-Type Coverage and Opportunities

**Scope.** This is a *coverage* analysis, not a usage guide. It answers: which **kinds**
of Given-When-Then tests does `reventless-gwt` support today (behavior, projection,
mapping, …), are all slice families covered, and what is genuinely missing — with a
focus on **multi-step / end-to-end GWT tests that span more than one slice**.

It complements, and does not repeat, the two existing GWT documents:

- [`docs/analysis/given-when-then-specifications.md`](given-when-then-specifications.md) — the pre-implementation **design rationale** (alternatives, Outcome algebra, format spec).
- [`docs/plans/done/reventless-gwt.md`](../plans/done/reventless-gwt.md) — the **phased rollout record** (Stages 1–12).

Files surveyed: every `*_GWT.res` in [`reventless/reventless-gwt/src/`](../../reventless/reventless-gwt/src/),
the PPX kind-mapping in [`packages/reventless-ppx/src/ppx/Util.ml`](../../packages/reventless-ppx/src/ppx/Util.ml),
and the existing `*_GWT.res` test files across the examples, `reventless-gwt/tests/`, and
`reventless-in-memory/tests/plugin/` (where the platform Plugin behavior/projection GWT
tests now live).

---

## 1. What "kind of GWT test" means here

A GWT *kind* is a DSL functor that knows how to fold one **component pattern** into a
Given-When-Then shape. Each kind defines its own `given* / when* / then*` vocabulary,
matched to what that pattern actually does (decide events, project state, collect todos,
translate inputs, …). The PPX picks the kind from the folder/filename and injects the
`include … _GWT.Make(Spec)` line, so a test file's *kind* is determined by **where it
lives**, not by what it imports.

The question "what kinds are supported" therefore decomposes into three sub-questions:

1. Is there a GWT DSL for every **component pattern** (every slice family + aggregate + read model)?
2. Are the **non-slice** wiring components (ExtensionPoint, Extension, Task) covered?
3. Is there any **cross-component** kind — a test that threads a scenario through *several* slices?

---

## 2. Coverage today: one DSL per pattern

Every behavioral pattern in the framework has a dedicated GWT DSL. The table is the
authoritative map from component pattern → DSL → functor → folder vocabulary the PPX
recognises.

| Component pattern | Folder(s) | GWT module | Functor | Async? | Status |
|---|---|---|---|---|---|
| **Aggregate** (command handling) | `Aggregate/` | [`Behavior_GWT`](../../reventless/reventless-gwt/src/Behavior_GWT.res) | `MakeFromAggregate(Spec, Behavior)` | sync | ✅ |
| **StateChangeSlice** (DCB command) | `StateChangeSlice/`, `StateChange/` | [`Behavior_GWT`](../../reventless/reventless-gwt/src/Behavior_GWT.res) | `Make(Spec, Behavior)` | sync | ✅ (+ `thenAppendsConditionedOn`) |
| **StateViewSlice** (DCB view) | `StateViewSlice/`, `StateView/` | [`Projection_GWT`](../../reventless/reventless-gwt/src/Projection_GWT.res) | `Make(Spec, Projection)` | async | ✅ |
| **StateViewSliceStream** | `StateViewSliceStream/` | [`Projection_GWT`](../../reventless/reventless-gwt/src/Projection_GWT.res) | `Make(Spec, Projection)` | async | ✅ (same DSL) |
| **ReadModel** (multi-source projection) | `ReadModel/` | [`MultiSourceProjection_GWT`](../../reventless/reventless-gwt/src/MultiSourceProjection_GWT.res) | `Make(Projection)` | async | ✅ |
| **AutomationSlice** (policy / process) | `AutomationSlice/`, `Automation/` | [`Automation_GWT`](../../reventless/reventless-gwt/src/Automation_GWT.res) | `Make(Spec)` | sync | ✅ (unit + scenario) |
| **InboundTranslationSlice** | `InboundTranslationSlice/`, `InboundTranslation/` | [`InboundTranslation_GWT`](../../reventless/reventless-gwt/src/InboundTranslation_GWT.res) | `Make(Spec)` | sync | ✅ |
| **OutboundTranslationSlice** | `OutboundTranslationSlice/`, `OutboundTranslation/` | [`OutboundTranslation_GWT`](../../reventless/reventless-gwt/src/OutboundTranslation_GWT.res) | `Make(Spec)` | async + sync | ✅ |
| **EventMapping** (Agg↔DCB automation) | inferred from source/target | [`Mapping_GWT`](../../reventless/reventless-gwt/src/Mapping_GWT.res) | `Make(Mapping)` (+ `FromBehavior`, `FromStateChangeSlice` adapters) | async | ✅ (replaces legacy `EventMapping_GWT`) |
| **Query pattern** (read access) | applies to ReadModel / StateViewSlice | [`Query_GWT`](../../reventless/reventless-gwt/src/Query_GWT.res) | `Make(Spec)` (+ `FromReadModel`, `FromStateViewSlice`) | sync | ✅ |

**Conclusion for slices: complete.** All five slice families (StateChange, StateView,
Automation, InboundTranslation, OutboundTranslation), plus the two "classic" patterns
(Aggregate, ReadModel) and the two cross-cutting concerns (EventMapping, Query), each
have a first-class DSL. There is no slice family without a GWT kind.

### 2.1 The PPX vocabulary that selects a kind

[`Util.ml`](../../packages/reventless-ppx/src/ppx/Util.ml)'s `slice_base_to_kind` maps
folder names to kinds, accepting exact / plural / `Slice`-suffixed / `Slices` forms:

```
Automation          → Automation
InboundTranslation  → InboundTranslation
OutboundTranslation → OutboundTranslation
StateChange         → Behavior       (Aggregate too → Behavior via MakeFromAggregate)
StateView           → Projection
ReadModel           → MultiSourceProjection
```

Filename-suffix fallback (longest match first) recognises `OutboundTranslation`,
`InboundTranslation`, `Automation`, `StateChangeSlice`, `StateViewSlice`, `Projection`,
`Behavior` inside the stem after stripping `_GWT` / `GwtTest` / `Gwt`.

---

## 3. The gaps in *single-component* coverage

Three component kinds have **no** GWT DSL. Two of them are real opportunities; one is
correctly excluded.

### 3.1 ExtensionPoint mappings — **real gap, high value**

`ExtensionPoint/<Name>_ExtensionPointMapping.res` files contain a pure mapping module
(`open ReventlessInfra.ExtensionPointMapping` brings `PublishEvent`, `PublishCommand`,
`PublishEventAsync`, `Call` into scope). The mapping takes an inbound event/command and
returns a list of publish actions. **That is exactly the shape `Mapping_GWT` already
handles** — a pure input → published-output translation — yet there is no DSL pointed at
it, and the PPX has no kind for the `ExtensionPoint/` folder.

This matters because, per [`app-developer.md`](../../.claude/rules/app-developer.md),
**all cross-plugin communication flows through ExtensionPoint and Extension** components.
The one integration seam between plugins is currently the one behavioral seam with zero
GWT coverage. A `mapping → assert published events/commands/calls` DSL would close it:

```rescript
// hypothetical ExtensionPointMapping_GWT
whenInboundEvent(SomeEvent)
->thenPublishesCommand("targetPlugin", DoThing(...))
->thenPublishesNoEvent
```

### 3.2 Extension delegates — **real gap, same shape**

`Extension/<Name>_Extension.res` carries a `Delegate`/`Mapping` module
(`open ReventlessInfra.ExtensionMapping`) — again a pure translation into publish
actions. Same DSL family as 3.1; the two could share one `Delegate_GWT`/`Wiring_GWT`
kind with a `FromExtensionPoint` / `FromExtension` adapter pair, mirroring how
`Mapping_GWT` and `Query_GWT` use `From*` adapters to serve two patterns from one core.

### 3.3 Task — **correctly excluded for now**

`Task/<Name>.res` is a background job whose value is in its infrastructure interaction
(S3 buckets, schedules). The *pure* slice of a task (its decision over inputs) could be
GWT-tested, but the payoff is low and the boundary is fuzzy. Leave it to integration
tests unless tasks grow non-trivial pure logic. This matches the plan's "Out of scope"
stance on infra-bound components.

---

## 4. Multi-step capability that already exists (within one component)

"Multi-step" already exists in three narrow, **single-component** forms. Recognising
these clarifies what the genuinely-missing cross-slice form would add.

1. **Behavior given-history is multi-event.** `givenEvents([...])` folds an arbitrary
   prior history before the `whenCmd`. The platform Plugin behavior test
   [`PluginBehavior_GWT.res`](../../reventless/reventless-in-memory/tests/plugin/PluginBehavior_GWT.res)
   folds multi-event histories (e.g. `UnknownPluginDetected → Connected → Deactivated`)
   before the `whenCmd`. But this is still **one** slice deciding **one** command;
   the chain is in the *setup*, not in the *execution*.

2. **Automation scenario sweep.** `Automation_GWT` has a second combinator family —
   `givenEvents → whenSweep → thenCommands → andThenEvents → thenScenarioTodos` — that
   feeds a batch of events through collect/resolve/process and asserts the emitted
   commands *and* residual todos. This is the closest thing to a multi-event flow, but
   bounded to a single automation slice.

3. **Mapping is a two-component hop.** `Mapping_GWT` runs `Source.decide → map →
   Target.decide` and asserts the target's events: `givenSourceEvents → andTargetEvents →
   whenSourceCmd → thenTargetEvents`. This is genuinely two components — but it is *one
   hop*, and only the command→event→mapped-command→event hop. It cannot continue into a
   third component, a projection, or an outbound translation.

**The ceiling:** no DSL threads a scenario across an open-ended chain of slices, and none
crosses *pattern boundaries* mid-chain (e.g. command-slice → automation → command-slice →
view-slice). That is the missing kind.

---

## 5. The missing kind: cross-slice / end-to-end GWT

### 5.1 Why this is the real opportunity

Event Modeling describes a system as **connected slices on one board** — a command lands,
an event is recorded, a read model updates, a policy reacts and issues the next command,
an outbound translation fires an effect. A reviewer reading an Event Modeling diagram
reads a *flow*, not an isolated slice. Today every GWT test verifies one tile of that
board in isolation; nothing verifies that the **tiles connect** the way the diagram says.

What's currently used to test connected flows is the **in-memory E2E integration tests**
(e.g. [`DcbReadModelE2ETest.res`](../../reventless/reventless-in-memory/tests/components/readmodel/DcbReadModelE2ETest.res),
the DCB slice E2E pattern in MEMORY): they dispatch real commands through `InMemory_Bus`, await
`Output.apply` registration, and count events. These work, but they are **not GWT**:

- No `Outcome` algebra → not discoverable or runnable by the `reventless-gwt` CLI runner.
- Imperative bus wiring + `beforeAllAsync` resolution dance → not declarative, not the
  format the VS Code extension renders, not AI-derivable from an Event Modeling diagram.
- They live in `reventless-in-memory`, not beside the slices they exercise.

The plan acknowledges this explicitly: *"E2E tests … are integration tests, not GWTs …
Long term they could be expressed as `Mapping_GWT` scenarios but that's a separate
effort."* (`reventless-gwt.md`, §C). That separate effort is the opportunity.

### 5.2 Two distinct flavors — pick the pure one first

There are two ways to build a multi-slice GWT, and they have very different costs:

| | **A. Pure flow composition** | **B. Plugin/platform scenario** |
|---|---|---|
| Mechanism | Pipe pure `decide`/`evolve`/`project`/`collect` functions together in declared order | Boot the in-memory bus, wire the real plugin, dispatch and await |
| Infra | none | in-memory adapters + async bus |
| Speed / determinism | fast, fully deterministic | slower, async timing (`Output.apply` ticks) |
| Fits Outcome algebra | yes, trivially | needs an async Outcome bridge |
| AI-derivable from Event Modeling | yes — the diagram *is* the wiring | partially |
| What it proves | the slices' logic composes as drawn | the runtime wiring also composes |

**Recommendation: build A first.** It stays inside the GWT philosophy ("slices are pure;
no mocks needed" — plan §Out of scope), plugs directly into the existing `Outcome` + CLI
runner, and is the form an LLM can generate from a diagram. B is valuable as a smoke test
but largely duplicates what the existing E2E integration tests already do; only wrap it in
GWT once A exists and demand is proven.

### 5.3 Sketch of a pure `Flow_GWT` / `Scenario_GWT`

The wiring an LLM reads off an Event Modeling flow is: *which automation reacts to which
event, and which command it issues next.* A pure flow DSL takes that wiring as explicit
steps and threads an accumulating event log through them:

```rescript
// Flow_GWT composes deciders + automations + projections declared by the test.
// Each `when*` appends to a shared event log; each `then*` asserts against it.

givenEvents([])                                  // seed history (any slice's events)
->whenCommand(module(PlaceOrder), OrderId, Place(cart))    // StateChangeSlice decide → append
->thenEvents([OrderPlaced(...)])
->whenAutomationReacts(module(AutoShipOrder))    // feed new events → collect/process → command
->thenIssuesCommand(module(ShipOrder), ShipIt)
->whenCommand(module(ShipOrder), OrderId, ShipIt)
->thenEvents([OrderShipped(...)])
->thenViewState(module(Orders), OrderId, {status: Shipped, ...})   // project log → assert read state
->thenOutbound(module(SendOrderConfirmation), EmailSent(...))      // collect/translate → assert effect
```

Key design choices to resolve when this is planned:

- **Heterogeneous event log.** The shared log holds events from multiple specs. Either a
  JSON-erased log (each step (de)serialises through its spec's schema — consistent with how
  `Mapping_GWT` already carries `dict<array<Target.event>>`), or a GADT-ish existential
  wrapper. JSON-erasure is the lower-friction path and matches existing precedent.
- **Automation reaction is a function, not the bus.** `whenAutomationReacts` calls the
  slice's pure collect/process directly on the new events — no scheduler, no timers. Async
  automations are tested for their *output*, not their delivery.
- **DCB tag filtering must be honoured.** Per MEMORY, a flow that crosses DCB slices must
  filter the shared log by `@s.matches(DcbTag.string)` exactly as the runtime does, or
  downstream deciders see phantom cross-entity events. The DSL should filter per spec.
- **PPX kind + folder.** A `Flow/` or `Scenario/` folder (and `@@reventless.gwt(Flow)`)
  would let these live beside the plugin they exercise, with the PPX injecting the
  composition. Unlike other kinds the Spec is *plural/composite*, so the include shape
  differs — likely an explicit module list rather than a single `Make(Spec)`.

### 5.4 What it unlocks

- **Diagram fidelity.** A reviewer can read a `Flow_GWT` test top-to-bottom and check it
  against the Event Modeling board — the test *is* the flow.
- **Regression net for wiring changes.** Renaming an event, changing an automation's
  trigger, or altering a projection currently passes all isolated GWTs while silently
  breaking the chain. A flow test catches it.
- **Highest-leverage AI target.** §5 of the design doc notes the generation pipeline; a
  flow DSL is the artifact most directly derivable from a diagram (the connections are the
  arrows), so it's where AI generation pays off most.

---

## 6. The hybrid example as the Flow_GWT proving ground — and: is multi-plugin supported?

The §5 sketch is abstract. [`examples/online-shop-hybrid`](../../examples/online-shop-hybrid/)
is the concrete vehicle that should *anchor* a Flow_GWT effort, because it is the only
example that simultaneously (a) mixes Aggregate and DCB styles in production wiring, and
(b) runs **two plugins with a bidirectional cross-plugin choreography**. Every slice
family and both ExtensionPoint directions appear in one coherent e-commerce domain.

### 6.1 Is multi-plugin supported yet? Two different answers

**At the platform / runtime level: yes, fully.** Both
[`platform-in-memory`](../../examples/online-shop-hybrid/platform-in-memory/) and
[`platform-aws`](../../examples/online-shop-hybrid/platform-aws/) compose the `catalog`
and `ordering` plugins together, and cross-plugin communication is a first-class, working
mechanism. Two ExtensionPoints form a closed loop, with the shared boundary types living
in dedicated spec packages (so neither plugin imports the other's source — per
[`app-developer.md`](../../.claude/rules/app-developer.md)):

| ExtensionPoint (spec pkg) | Declared by | Consumed by | Boundary events | Drives |
|---|---|---|---|---|
| `Products_ExtensionPoint` (`catalog-spec`) | Catalog `ExtensionPoint/Products_ExtensionPointMapping.res` | Ordering `Extension/Products_Extension.res` | `ProductBecameAvailable`, `ProductPriceChanged` | `SyncCatalogProduct` (shadow copy) |
| `Orders_ExtensionPoint` (`ordering-spec`) | Ordering `ExtensionPoint/Orders_ExtensionPointMapping.res` | Catalog `Extension/Orders_Extension.res` | `ItemOrdered`, `ItemOrderCancelled` (per-product, array-decomposed) | `RecordProductDemand` |

The in-memory bus routes the commands these extensions publish across the plugin
boundary; the existing E2E integration tests in `reventless-in-memory` already prove this
end to end.

**At the GWT level: no — not even cross-slice, let alone cross-plugin.** All 25 hybrid
GWT files (12 catalog + 13 ordering) are single-component. Nothing threads a scenario
across a slice boundary, and the cross-plugin seam itself — the EP `mapOutgoingEvent`
mapping and the Extension delegate — has **zero** GWT coverage (the §3.1/§3.2 gap). So
multi-plugin behavior today is verifiable only through imperative, bus-based E2E tests,
never as a declarative GWT.

This is the crux: **the §3 EP/Extension gap is exactly the primitive a cross-plugin
Flow_GWT needs.** Closing it is not just unit-testing two mapping files — it provides the
boundary step that lets a flow continue from one plugin into the next.

### 6.2 Three tiers of Flow_GWT the hybrid example unlocks

**Tier 1 — single-plugin, multi-slice (Ordering only).** No EP/Extension primitive needed;
buildable on the pure `Flow_GWT` of §5.3 alone:

```
PlaceOrder ─→ OrderPlaced
  ├─ Orders (StateViewSlice)            : status = Placed
  ├─ AutoShipOrder (AutomationSlice)    : todo → ShipOrder ─→ OrderShipped → todo resolved
  │     └─ Orders                       : status = Shipped
  └─ SendOrderConfirmation (Outbound)   : EmailService.sendOrderConfirmation fired once
```

A single test asserts the command, the auto-issued follow-up command, the read-model
state after both events, *and* the outbound effect — the whole Event-Modeling lane in one
declarative chain. No isolated GWT proves these tiles connect.

**Tier 2 — cross-plugin, forward (Catalog → Ordering).** This is the most compelling
demo, because the payoff is invisible to any single-slice test:

```
Catalog: AddProduct ─→ ProductAdded
  └─[Products_ExtensionPoint mapping]→ ProductBecameAvailable
       └─[Ordering Products_Extension]→ SyncNewProduct
            └─ Ordering: SyncCatalogProduct ─→ CatalogProductSynced
                 └─ AvailableProducts (StateViewSlice, Internal) : product now known
Ordering: PlaceOrder(productIds:["p1"]) ─→ OrderPlaced   ← SUCCEEDS only because of the sync
```

`PlaceOrder`'s behavior validates `productIds` against `availableProductIds`, which is
populated **only** through the cross-plugin sync. A Tier-2 flow test therefore proves the
two plugins *agree about reality* — that a product added in Catalog is orderable in
Ordering. That property is structurally untestable with the current single-component DSLs.

**Tier 3 — cross-plugin, round trip (the demand loop).** Exercises array decomposition and
the second ExtensionPoint, closing the loop back into Catalog:

```
Ordering: PlaceOrder(productIds:["p1","p2"]) ─→ OrderPlaced
  └─[Orders_ExtensionPoint mapping, fan-out]→ ItemOrdered(p1), ItemOrdered(p2)   (one→many)
       └─[Catalog Orders_Extension]→ RecordDemand(p1), RecordDemand(p2)
            └─ Catalog: RecordProductDemand ─→ ProductDemandRecorded ×2
                 └─ ProductDemand (StateViewSliceStream) : orderCount p1=1, p2=1
Ordering: CancelOrder ─→ OrderCancelled ─[fan-out]→ ItemOrderCancelled ×2 ─→ RevokeDemand ×2
                 └─ ProductDemand : orderCount back to 0   (mirror path)
```

### 6.3 What the DSL must add for the cross-plugin step

Beyond the pure-flow requirements in §5.3, Tiers 2–3 need:

- **An ExtensionPoint/Extension boundary step.** The flow must invoke the EP
  `mapOutgoingEvent` and the Extension delegate as pure functions — i.e. the §3.1/§3.2
  kind. Sketch: `…->whenPublishedThrough(module(Products_ExtensionPoint)) ->thenPublicEvent(ProductBecameAvailable({...})) ->whenExtensionReacts(module(Products_Extension)) ->thenIssuesCommand(module(SyncCatalogProduct), SyncNewProduct({...}))`.
- **One-to-many hops.** EP mappings fan out (`OrderPlaced{productIds:[…]}` → N×`ItemOrdered`).
  The boundary step's `then*` assertions must accept a *set* of published events, not one.
- **Two-plugin heterogeneous log + per-plugin DCB tag filtering.** The shared scenario log
  spans both plugins' event types (JSON-erased per §5.3), and each downstream DCB decider
  must see only its own plugin's tag-filtered slice, exactly as the runtime routes it.
- **Boundary types from spec packages, not plugin sources.** The DSL references
  `catalog-spec` / `ordering-spec` for the EP events, preserving plugin isolation — the
  flow test never imports across the plugin boundary, mirroring production wiring.

### 6.4 Consequence for sequencing

Because cross-plugin Flow_GWT *depends* on the EP/Extension kind, the EP/Extension mapping
DSL is promoted from "nice small win" to "the boundary primitive for multi-plugin testing."
Single-plugin (Tier 1) Flow_GWT and the EP/Extension DSL are independent and can proceed in
either order; cross-plugin (Tier 2–3) Flow_GWT layers on both. The hybrid example then
doubles as the worked-example suite the runner and VS Code extension render.

---

## 7. Smaller, already-noted refinements

These are deferred items the plan itself flagged — worth tracking but lower priority than §5.

| Item | Where | Note |
|---|---|---|
| **Cross-spec query resolvers** | `Query_GWT` | `givenStore_for` / `whenResolve` / `whenResolveMany` deferred; needs `Make2(Primary, Secondary)` or JSON-erased store. Single-spec covers PK + indexed + composite today. |
| **Outbound retry counter** | `OutboundTranslation_GWT.thenRetryRecorded(n)` | Asserts `Error(_)` but doesn't track a real counter — `n` documents intent only. Tighten once a runner carries scenario state. |
| **`thenSourceErrorWithEvents`** | `Mapping_GWT` | Deliberately omitted (source error ⇒ no target events ⇒ the pair is always empty). Not a gap. |
| **GWT self-tests in DSL shape** | runner internals | `RunnerUnitTest.res` stays Jest-only by design; the DSL worked-examples exercise the CLI end-to-end. Not a gap. |

---

## 8. Summary

- **Slice coverage is complete.** All five slice families plus Aggregate, ReadModel,
  EventMapping, and Query each have a dedicated GWT DSL, selected automatically by the PPX
  from folder/filename. No behavioral pattern is missing a kind.
- **Two single-component gaps are real:** **ExtensionPoint mappings** and **Extension
  delegates** are pure input→publish translations — the exact shape `Mapping_GWT` already
  handles — yet have no DSL, despite being the *only* cross-plugin behavioral seam. Closing
  them with a shared `Wiring`/`Delegate` GWT kind (via `From*` adapters) is the
  highest-value *small* addition. **Task** is correctly left to integration tests.
- **The headline opportunity is the cross-slice / end-to-end kind.** Multi-step exists
  today only *within* a single component (Behavior history, Automation sweep) or for a
  *single* two-component hop (`Mapping_GWT`). Nothing threads a scenario across an
  open-ended chain that crosses pattern boundaries — the very thing an Event Modeling
  diagram depicts. Existing in-memory E2E tests cover connected flows but are not GWT
  (not declarative, not runner-discoverable, not AI-derivable). A **pure `Flow_GWT`** that
  composes existing pure deciders/automations/projections into one Given-When-Then chain
  fills this gap inside the existing Outcome + CLI substrate, and is the most directly
  AI-generatable artifact from a diagram. A heavier bus-backed `Scenario_GWT` is a
  second-order follow-up that mostly re-expresses today's integration tests.

- **Multi-plugin is supported by the runtime but not by GWT.** The hybrid example
  (§6) composes two plugins with a bidirectional cross-plugin loop (two ExtensionPoints +
  spec packages), and the in-memory bus routes commands across the boundary — proven today
  only by imperative E2E integration tests. No GWT crosses a slice boundary, let alone a
  plugin boundary, and the cross-plugin seam (EP mapping + Extension delegate) has zero GWT
  coverage. `examples/online-shop-hybrid` is the ideal proving ground for cross-slice and
  cross-plugin Flow_GWT, including the killer property no single-slice test can assert: a
  product added in Catalog becomes orderable in Ordering only via the cross-plugin sync.

**Suggested ordering:** (1) single-plugin pure `Flow_GWT` (Tier 1) and (2) the
ExtensionPoint/Extension mapping DSL — now also the cross-plugin **boundary primitive** —
can proceed in either order; (3) cross-plugin `Flow_GWT` (Tiers 2–3) layers on both, with
the hybrid example as its worked-example suite; (4) deferred `Query_GWT` resolvers and
outbound retry state last.
