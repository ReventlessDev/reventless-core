# Given-When-Then Specifications in Reventless

Analysis of the framework's Given-When-Then (GWT) specification support for Event Modeling slices, the gap between Aggregate-side and DCB-side test DSLs, the case for moving the test helpers into `reventless-spec`, and how far AI-assisted generation of implementation+tests from a GWT corpus can go.

---

## 1. What Event Modeling expects from a GWT layer

Event Modeling, as captured in [`docs/analysis/event-modeling-comparison.md`](../analysis/event-modeling-comparison.md), reduces every information system to four slice patterns. Each pattern has a canonical Given-When-Then shape:

| Slice | Given | When | Then |
|-------|-------|------|------|
| **Command (state-change)** | prior events on the entity | command issued | new event(s) emitted, OR an error |
| **View (state-view)** | prior events | view queried (or projection invoked) | rows returned / state shape |
| **Automation (TODO list / processor)** | events that build the TODO list | a tick / new event arrives | command(s) issued, TODO marked done |
| **Translation (anti-corruption)** | external input OR domain events | translator runs | command(s) emitted to internal system OR external call made (idempotent) |

The framework's component model mirrors this 1:1 (see [`docs/analysis/event-source-connection-matrix.md`](../analysis/event-source-connection-matrix.md)):

| Pattern | Aggregate world | DCB world |
|---------|-----------------|-----------|
| Command | `Aggregate` + `Behavior` | `StateChangeSlice` |
| View | `ReadModel` + `Projection.Mapping` | `StateViewSlice` |
| Automation | `EventMapping` (publish/publishDelayed/publishAsync) | `AutomationSlice` |
| Translation (in) | API/handler code | `InboundTranslationSlice` |
| Translation (out) | `SideEffectHandler` | `OutboundTranslationSlice` |

A complete GWT layer needs a DSL for **every cell of that table**, with consistent shape so the same example can be expressed the same way regardless of which architectural style the slice is implemented in.

---

## 2. Current state — what exists and where

All three existing DSLs live in `reventless-core/tests/` (and a near-duplicate of `BehaviorTest`/`ProjectionTest`/`AsyncTest` in `reventless-in-memory/src/test/`).

### 2.1 [BehaviorTest](../../reventless/reventless-core/tests/BehaviorTest.res) — Aggregate command slice

Pure synchronous DSL. Functor over `(Spec, Behavior)`:

```rescript
include ReventlessInMemory.BehaviorTest.Make(Category, CategoryBehavior)

test("on new aggregate produces Added", () =>
  givenEvents([])
  ->whenCmd(Add({name: "Electronics"}))
  ->thenEvent(Added({name: "Electronics"})))
```

Combinators: `givenEvents`, `whenCmd`, `thenEvent`, `thenEvents`, `thenNoEvent`, `thenError`, `thenEventWithError`, `thenCompareEvent(s)`. Errors captured in a `ref` and asserted alongside events.

Strengths: idiomatic, matches Behavior shape exactly, no async overhead.
Limitations: only one entity stream; no notion of multiple `id`s in the history. Adequate for Aggregate where a Behavior is anchored to one ID.

### 2.2 [EventMappingTest](../../reventless/reventless-core/tests/EventMappingTest.res) — Aggregate→Aggregate automation

Async DSL composing two aggregates and one `EventMapping`. Functor over `(Source, SourceBehavior, Target, TargetBehavior, EventMapping)`:

```rescript
givenSourceEvents([CategoryArchived(...)])
->givenTargetEvents([("p-1", [ProductAdded(...)])])
->whenSourceCmd("c-1", ArchiveCategory(...))
->thenTargetEvent("p-1", ProductArchived(...))
```

Strengths: covers the cross-aggregate flow including the QueryEngine stub for async lookups; respects target-aggregate behavior so target invariants are enforced.
Limitations: only `Aggregate→Aggregate` automation; no support for `PublishDelayed` time travel; `thenTargetError` family commented out; no integration with DCB sources or targets.

### 2.3 [ProjectionTest](../../reventless/reventless-core/tests/ProjectionTest.res) — ReadModel projection

Async DSL with a synthetic in-memory store. Functor over `Projection.Mapping`:

```rescript
givenEvents([CategoryAdded(...)])
->whenEvent(CategoryRenamed(...))
->thenState({categoryId: "c1", name: "Consumer Electronics", archived: false})
```

Combinators: `givenEvents(WithTime)`, `whenEvent(s)(WithTime)`, `thenState(s)`, `thenStateWithId`, `thenAllStates`, `thenNoState`, `thenThrow`, `thenFail`. Honors `subIdConfig` for composite-key tables and exercises `Projection.handleActions` against the full save/load/delete adapter shape.

Strengths: most complete DSL — supports time, sub-IDs, multi-state, all `Projection.action` variants.
Limitations: drives one mapping at a time. If a read model has multiple `Projection.Mapping`s (multi-source), they have to be tested independently.

### 2.4 DCB slices — no DSL at all

Every DCB example test does this directly:

```rescript
// CategoryDecisionTest.res — typical DCB StateChangeSlice unit test
test("on existing category returns CategoryAlreadyExists", () =>
  expect(
    AddCategory.decide(
      {AddCategory.exists: true, archived: false},
      AddCategory.AddCategory({categoryId: "c1", name: "Electronics"}),
    ),
  )->toEqual(Error(AddCategory.CategoryAlreadyExists)))
```

Boilerplate-heavy, hand-evolved state, no `givenEvents` (you build state with the constructor record), no `thenError` semantics, and no parallel to the GWT vocabulary. Same for `StateViewSlice` (raw `expect(project(event))->toEqual([...])`). DCB E2E tests dispatch real commands through the in-memory bus and count emitted events — useful, but expensive and not written in GWT terms.

### 2.5 Coverage matrix

| Slice / Concern | Has DSL? | Where | GWT vocab | DCB-aware |
|---|---|---|---|---|
| Aggregate Behavior | yes | `reventless-core/tests/BehaviorTest.res` | yes | n/a |
| Aggregate→Aggregate Mapping | yes | `reventless-core/tests/EventMappingTest.res` | partial (no error then) | n/a |
| ReadModel Projection | yes | `reventless-core/tests/ProjectionTest.res` | yes | n/a |
| StateChangeSlice | **no** | hand-rolled per slice | no | needs DCB tag awareness |
| StateViewSlice | **no** | hand-rolled per slice | no | needs DCB event awareness |
| AutomationSlice | **no** | none | no | needs collect/resolve/process loop |
| InboundTranslationSlice | **no** | none | no | needs translate semantics |
| OutboundTranslationSlice | **no** | none | no | needs translate + retry semantics |
| Cross-pattern Mapping (Aggregate→DCB or DCB→Aggregate) | **no** | none | no | n/a |

---

## 3. Should the DSL move to `reventless-spec`?

### 3.1 Current dependency layering

| Package | Depends on | Has Jest? |
|---|---|---|
| `reventless-spec` | `sury` only | no |
| `reventless-core` | `sury`, `@glennsl/rescript-jest`, ... | yes |
| `reventless-in-memory` | `reventless-core`, jest globals | yes |

So `BehaviorTest` etc. live in `reventless-core/tests/` because they need Jest. They are re-published from `reventless-in-memory/src/test/` (with subtle drift) so example packages don't need a direct `reventless-core` dev dependency.

### 3.2 Tension

The slice **specs** themselves (the things being tested) all already live in `reventless-spec` — `Behavior`, `StateChangeSlice`, `StateViewSlice`, `AutomationSlice`, `Inbound/OutboundTranslationSlice`, `EventMapping`, `Projection.Mapping`, `ReadModel`. The test DSLs are the only piece of the contract that lives one layer up. That asymmetry is the source of the duplication and drift between `reventless-core/tests/BehaviorTest.res` and `reventless-in-memory/src/test/BehaviorTest.res`.

### 3.3 Three placement options

**A. Move to `reventless-spec` (pure-spec dependency)**
- Add a thin `Test` namespace to `reventless-spec` with `Behavior_GWT.res`, `StateChangeSlice_GWT.res`, `StateViewSlice_GWT.res`, `AutomationSlice_GWT.res`, `InboundTranslation_GWT.res`, `OutboundTranslation_GWT.res`, `EventMapping_GWT.res`, `Projection_GWT.res`.
- Keep them runner-agnostic: each combinator returns `result<unit, mismatch>` or a structured `outcome` value rather than a `Jest.assertion`. Then a thin `reventless-spec-jest` (or `reventless-spec/src/runners/Jest.res`) adapter binds them to Jest.
- Pros: single source of truth co-located with the spec; keeps `reventless-spec` runtime-free; example packages can pick their own runner; the DSL becomes part of the public spec contract that both code and AI generators target.
- Cons: invents a small assertion algebra; example packages need one extra adapter import.

**B. Move to `reventless-spec` with a Jest peer dep**
- Same as A but commit to Jest as the runner. Add `@glennsl/rescript-jest` as a peer dep of `reventless-spec`.
- Pros: zero indirection for current callers, eliminates the `reventless-core/tests` ↔ `reventless-in-memory/src/test` duplication immediately.
- Cons: forces every `reventless-spec` consumer to ship Jest in their dep tree, even at production time; couples the spec layer to a test runner.

**C. Promote a new `reventless-spec-test` package**
- New sibling package under `reventless/`, depending on `reventless-spec` + Jest, owning all GWT DSLs.
- Pros: clean dependency story; downstream picks `reventless-spec-test` instead of pulling Jest into spec; mirrors how `reventless-aws-test`-style auxiliary packages would work.
- Cons: another package to publish; requires repointing `reventless-in-memory`'s re-exports.

### 3.4 Recommendation

**Option C** is the cleanest fit for this monorepo: the spec stays runtime-free, the new package is the one and only home of every GWT DSL, and `reventless-in-memory/src/test/*.res` becomes a paper-thin re-export (or is deleted entirely). It also gives a natural home for the missing DCB DSLs without re-opening the layering question every time.

Option A is a strong second choice if you want to push toward runner independence later (e.g. for a CLI-driven AI verification loop that doesn't need Jest at all).

---

## 4. The missing DSLs — proposed shapes

All shapes assume the test packages get DCB tag introspection via `Reventless.DcbTag` and event decoding via `Reventless.DcbDecode` (both already in `reventless-spec`).

### 4.1 `StateChangeSlice_GWT`

```rescript
include StateChangeSlice_GWT.Make(AddCategory)

describe("AddCategory", () => {
  test("on empty event log produces CategoryAdded", () =>
    givenEvents([])  // raw consumedEvents — slice's own type
    ->whenCmd(AddCategory({categoryId: "c1", name: "Electronics"}))
    ->thenEvent(CategoryAdded({categoryId: "c1", name: "Electronics"})))

  test("rejects when category already exists", () =>
    givenEvents([CategoryAdded])  // payload-less consumed shape allowed
    ->whenCmd(AddCategory({categoryId: "c1", name: "X"}))
    ->thenError(CategoryAlreadyExists))
})
```

Implementation: `Make(Spec: StateChangeSlice.Spec)` runs `evolve` over the given consumed events to build state, then calls `decide(state, command)`. Identical mental model to `BehaviorTest`, but typed against `Spec.consumedEvent` and `Spec.event` (which need not be the same type — the GWT layer must respect this).

For testing **DCB tag extraction** (which is part of the slice's behavior), add `thenAppendCondition` so a slice can be specified with the conditional append it expects to issue:

```rescript
->whenCmd(AddCategory({categoryId: "c1", name: "X"}))
->thenAppendsConditionedOn([{eventTypes: ["CategoryAdded"], tags: [{key: "categoryId", value: "c1"}]}])
->thenEvent(CategoryAdded({categoryId: "c1", name: "X"}))
```

This nails down the optimistic-concurrency contract — currently invisible in any test.

### 4.2 `StateViewSlice_GWT`

Mirrors `ProjectionTest` but driven by the slice's `consumedEvent`:

```rescript
include StateViewSlice_GWT.Make(CategoriesView)

givenEvents([CategoryAdded({categoryId: "c1", name: "X"})])
->whenEvent(CategoryRenamed({categoryId: "c1", name: "Y"}))
->thenState("c1", {categoryId: "c1", name: "Y", archived: false})
```

Internally reuses `Projection.handleActions` against an in-memory dict store, exactly like `ProjectionTest`. The only delta is no `Projection.Mapping` indirection — the slice's `project` function consumes the event directly.

### 4.3 `AutomationSlice_GWT`

Three GWT operations exercised independently and one composed scenario test:

```rescript
include AutomationSlice_GWT.Make(ShipOrder)

// Unit GWT — collect
givenEvent(OrderPlaced({orderId: "o1", shippingAddress: "..."}))
->whenCollect
->thenTodos([("o1", {orderId: "o1", shippingAddress: "..."})])

// Unit GWT — resolve
givenEvent(ShipmentCreated({orderId: "o1"}))
->whenResolve
->thenResolved(Some("o1"))

// Unit GWT — process
givenTodo("o1", {orderId: "o1", shippingAddress: "..."})
->whenProcess
->thenCommand("o1", CreateShipment({orderId: "o1", address: "..."}))

// Scenario GWT — full loop
givenEvents([OrderPlaced({orderId: "o1", ...})])
->whenSweep  // run collect→process for every pending TODO
->thenCommands([("o1", CreateShipment({...}))])
->andThenEvents([ShipmentCreated({orderId: "o1"})])  // close the loop
->thenTodos([])  // resolved
```

### 4.4 `InboundTranslationSlice_GWT`

```rescript
include InboundTranslationSlice_GWT.Make(PaymentWebhook)

whenInput({paymentId: "p1", orderId: "o1", status: "completed"})
->thenCommands([("o1", ConfirmPayment({orderId: "o1", paymentId: "p1"}))])

whenInput({paymentId: "p1", orderId: "o1", status: "garbage"})
->thenTranslateError("Unknown payment status: garbage")
```

No `given` clause — translation has no prior state.

### 4.5 `OutboundTranslationSlice_GWT`

The translate function is async and may produce a follow-up command. The DSL needs to mock the external service:

```rescript
include OutboundTranslationSlice_GWT.Make(SendTrackingEmail)

givenEvent(OrderShipped({orderId: "o1", email: "x@y"}))
->whenCollect
->thenTodos([("o1", {orderId: "o1", email: "x@y"})])

givenTodo("o1", {orderId: "o1", email: "x@y"})
->whenTranslateMocked(item => Promise.resolve(Ok(None)))  // fire-and-forget success
->thenNoCommand
->thenTodoStatus("o1", #Completed)

givenTodo("o1", {orderId: "o1", email: "x@y"})
->whenTranslateMocked(_ => Promise.resolve(Error("smtp down")))
->thenRetryRecorded(1)
->thenTodoStatus("o1", #Pending)
```

### 4.6 Cross-pattern automation

Generalize `EventMappingTest` so the source and target can each be either an Aggregate Behavior **or** a StateChangeSlice. This is the GWT equivalent of [`event-source-connection-matrix.md`](../analysis/event-source-connection-matrix.md)'s observation that the framework now needs to support all four producer/consumer combinations. The functor should accept `module(Source.T)` where `Source.T` abstracts Behavior + StateChangeSlice via a small Spec record (`name`, `decide`, `evolve`, `initialState`, `event`, `consumedEvent`).

---

## 5. Runtime independence — the assertion algebra

Both Option A and Option C above hinge on extracting a runner-agnostic core. Concretely:

```rescript
// reventless-spec/src/test/Outcome.res
type mismatch =
  | EventsMismatch({expected: array<JSON.t>, actual: array<JSON.t>})
  | ErrorMismatch({expected: JSON.t, actual: option<JSON.t>})
  | StateMismatch({key: string, expected: JSON.t, actual: option<JSON.t>})
  | NoEventExpected({actual: array<JSON.t>})
  | TodoMismatch({...})
  | AppendConditionMismatch({...})

type outcome = result<unit, mismatch>
```

Each `then*` combinator becomes `outcome` instead of `Jest.assertion`. A small adapter binds them:

```rescript
// reventless-spec-test/src/JestRunner.res
let assert_ = (o: Outcome.outcome) => switch o {
  | Ok(_) => Jest.pass
  | Error(m) => Jest.fail(Outcome.format(m))
}
```

This single change lets every DSL drive both Jest tests *and* an AI feedback loop (Section 7) that needs to compare expected vs actual programmatically without booting a runner.

---

## 6. Implementation plan

A staged approach minimizes churn:

1. **Stage 1 — Consolidate.** Create `reventless-spec-test` (Option C). Move `BehaviorTest`, `EventMappingTest`, `ProjectionTest`, `AsyncTest` from `reventless-core/tests/` into it. Delete the duplicates in `reventless-in-memory/src/test/`. Update `reventless-in-memory` re-exports to point at the new package. Update example tests to import via `ReventlessSpecTest` alias.

2. **Stage 2 — Outcome algebra.** Refactor combinators to return `Outcome.outcome` and add the `JestRunner` adapter. Existing test files do not change because the adapter wraps the outcome at the `test(...)` boundary, not in the `then*` calls.

3. **Stage 3 — DCB DSLs.** Add `StateChangeSlice_GWT`, `StateViewSlice_GWT`, `AutomationSlice_GWT`, `Inbound/OutboundTranslationSlice_GWT`. Each module mirrors the BehaviorTest API surface so the DCB tests stop hand-rolling state.

4. **Stage 4 — `thenAppendsConditionedOn`.** Add the conditional-append assertion to `StateChangeSlice_GWT` so the DCB optimistic-concurrency contract becomes specifiable (currently a runtime-only concern).

5. **Stage 5 — Cross-pattern Mapping DSL.** Generalize `EventMappingTest` so source and target can be Behavior or StateChangeSlice. Use this to spec the connections from [`event-source-connection-matrix.md`](../analysis/event-source-connection-matrix.md).

6. **Stage 6 — `reventless-ppx` integration.** A new `@@reventless.gwt` file-level annotation on `*Test.res` files inside `BehaviorTest/`, `StateChangeSliceTest/`, etc. could auto-inject the right `include ...Make(...)` line based on folder convention, the same way `@@reventless.spec` and `@@reventless.behavior` already do. This eliminates the boilerplate first line of every test file.

7. **Stage 7 — Documentation.** A new `docs/guides/given-when-then.md` that mirrors the four-slice table from Section 1, with one fully-worked example per slice type. Cross-link from `docs/guides/component-testing-guide.md`.

---

## 7. AI-assisted generation: how far can it go?

Given a corpus of:

- Reventless component **specs** (the `*.res` files under `Aggregate/`, `StateChangeSlice/`, etc.)
- A set of **GWT scenarios** in either ReScript or a Markdown/JSON DSL
- The framework's **PPX conventions** and **placement rules** (already encoded in `.claude/rules/` and CLAUDE.md)

…how completely can the implementation + tests be generated?

### 7.1 What is mechanically derivable

These are direct projections from the GWT examples and existing schemas:

| Artifact | Source of truth | Derivability |
|---|---|---|
| Command/event/error type variants | enumeration of `whenCmd` / `thenEvent` constructors in the GWT corpus | **trivial** |
| Sury `@schema` annotations | from the type definitions | **trivial** |
| DCB tag annotations (`@s.matches(DcbTag.string)` etc.) | enumeration of `*Id` field patterns + plurality (singular vs `array<>`) per CLAUDE.md PPX rules | **mechanical** (the PPX itself does this — AI just emits the field types) |
| `consumedEvent` set (DCB slices) | the union of constructors used in `givenEvents` clauses | **trivial** |
| `state` shape for `evolve` | the smallest record that satisfies all `decide` branches needed by the GWT examples | **derivable with a search** (smaller than naive — needs cost function) |
| `evolve` body | one branch per consumed event, computed from `givenEvents → state → whenCmd` examples | **derivable** but ambiguous when GWT corpus is incomplete |
| `decide` body | one branch per `whenCmd`, computed from `state → command → events` examples | **derivable but lossy** — see 7.3 |
| `Projection.action` choices in `project` | derivable from `givenEvents → store, whenEvent → store` deltas | **mechanical** for `Set/Update/Delete`; ambiguous for `UpdateWithDefault` vs `Set` |
| StateChangeSlice append-condition query | the union of tagged fields used in the `decide` decision predicate, intersected with consumed event types | **mechanical** once the slice body exists |
| Plugin wiring (`Plugin.res`) | already generated by `generate-plugin` from folder layout | **already automated** (no AI needed) |

### 7.2 What needs LLM judgment

These are not mechanical — they need design-level inference:

- **Whether a slice is Aggregate, DCB StateChangeSlice, or both** — the [`aggregate-vs-dcb-decision-guide.md`](../guides/aggregate-vs-dcb-decision-guide.md) encodes the heuristic. An LLM applying it needs to read the GWT corpus and decide whether the cross-entity invariants imply DCB.
- **Naming and folder placement** — covered by `.claude/rules/app-developer.md` conventions.
- **`evolve` minimality** — many `state` shapes satisfy the same GWT corpus. An LLM should bias toward the smallest sum of fields, but that is a judgment call.
- **Idempotency choices** — when `whenCmd(X)->thenNoEvent` is given on an already-effected state, the LLM must decide whether to return `Ok([])` (idempotent, app-developer rule) or `Error(SomeError)`. The convention says idempotent.
- **Error taxonomy** — naming `CategoryAlreadyExists` vs `DuplicateAdd` is a design choice not pinned by GWT examples.

### 7.3 What CANNOT be derived

These are domain decisions that the GWT corpus must specify, or generation will fail / hallucinate:

- **Cross-entity invariants** that aren't exercised by any example — there is no way to know "you cannot place an order for an archived product" without a GWT scenario that demonstrates it.
- **Side-effect contracts** beyond what's recorded in events.
- **Read model query patterns** (indexes, sub-IDs, AppSync auth) — these are not implied by Given/When/Then on the projection. They need their own spec ("Given these query patterns, the read model must support…"). A `QueryGWT` could plug this gap: `givenStore([...]) → whenQuery({by: "categoryId", id: "c1"}) → thenRows([...])`.

### 7.4 Recommended generation pipeline

The realistic AI workflow that emerges:

1. **Input**: domain spec packages (`*Spec/`) + GWT corpus (one `.gwt.md` or `.res` file per scenario).
2. **Stage A (mechanical)**: derive component skeletons — folder layout, file names, type declarations with PPX annotations. This stage is rule-based, not LLM-based; an extension of `generate-plugin` could do it.
3. **Stage B (LLM)**: synthesize `evolve` and `decide` bodies from each scenario, using the typed AST as a constraint surface. The LLM's output is locally verifiable: compile + run the GWT scenario; if all `then*` clauses hold, accept; else iterate.
4. **Stage C (LLM)**: synthesize `project` bodies for view slices — same loop using `ProjectionTest` / `StateViewSlice_GWT`.
5. **Stage D (LLM with bounded creativity)**: derive `idResolvers`, `indexes`, `subIdConfig` from a separate `QueryGWT` corpus.
6. **Stage E (mechanical)**: run `generate-plugin`, build, run all GWT tests as the acceptance gate.

The Outcome algebra (Section 5) is the key enabler for stages B–D: because `then*` produces `result<unit, mismatch>` rather than throwing into Jest, the LLM-driven loop can read structured failure data and target a fix without parsing test output.

### 7.5 What unlocks the highest leverage

In priority order:

1. **Build the missing DCB DSLs (Sections 4.1–4.6).** Without them, the GWT corpus can only describe Aggregate slices — half the framework is invisible to the AI loop.
2. **Adopt the Outcome algebra (Section 5).** Without structured failures, AI iteration depends on parsing Jest output, which is fragile and slow.
3. **Add `QueryGWT` for read models.** Closes the "what indexes/resolvers do we need" gap so query design isn't a separate manual step.
4. **Encode the four GWT shapes as a JSON schema.** Lets AI tools accept declarative inputs (or Event Modeler exports) and emit ReScript GWT files. Pairs with the existing [`event-modeling-json-reventless-conversion.md`](../analysis/event-modeling-json-reventless-conversion.md) work.
5. **PPX `@@reventless.gwt`** to remove the `include ...GWT.Make(...)` boilerplate and lock the convention down.

With all five in place, "I provide the spec and the GWT" → "framework runs, passes" becomes a closed AI iteration loop, with the Outcome algebra serving as the fitness function.

---

## 8. Summary of recommendations

- **Move the GWT DSLs to a new `reventless-spec-test` package** (Option C); keep `reventless-spec` runtime-free.
- **Refactor `then*` to return `Outcome.outcome`**; bind to Jest via a thin adapter so the same algebra drives AI iteration.
- **Add five missing DSLs**: `StateChangeSlice_GWT`, `StateViewSlice_GWT`, `AutomationSlice_GWT`, `InboundTranslationSlice_GWT`, `OutboundTranslationSlice_GWT`. They mirror `BehaviorTest`/`ProjectionTest`'s shape so users learn one vocabulary.
- **Generalize `EventMappingTest`** so source and target can each be Behavior or StateChangeSlice — closes the cross-pattern gap in [`event-source-connection-matrix.md`](../analysis/event-source-connection-matrix.md).
- **Add `thenAppendsConditionedOn`** to `StateChangeSlice_GWT` so DCB optimistic-concurrency conditions become specifiable.
- **AI generation is feasible up to a high ceiling**, but only if the GWT corpus covers every cross-entity invariant. The two non-derivable areas — cross-entity invariants without examples, and read-model query patterns — must be made explicit as scenarios. Otherwise an LLM will under-constrain `decide` and over-fit on the supplied examples.
