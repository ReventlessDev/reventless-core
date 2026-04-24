# Given-When-Then Testing in Reventless

Reventless ships a dedicated Given-When-Then (GWT) test framework,
[`@reventlessdev/reventless-gwt`](../../reventless/reventless-gwt/), with a DSL
for every Event Modeling slice type, a runner-agnostic `Outcome` algebra, and a
standalone CLI runner (`reventless-gwt`) with five output formats (human, JSON,
TAP, JUnit, VS Code Testing API).

This guide is the canonical reference for writing slice-level tests. For the
design rationale, alternatives considered, and detailed format specifications
see
[`docs/analysis/given-when-then-specifications.md`](../analysis/given-when-then-specifications.md).

---

## 1. Pick the DSL for your slice

Event Modeling has four slice patterns; Reventless's component model provides
an Aggregate implementation and a DCB implementation of each:

| Pattern                      | Aggregate world                   | DCB world                       | GWT DSL                                                        |
|------------------------------|-----------------------------------|---------------------------------|----------------------------------------------------------------|
| Command (state change)       | `Aggregate` + `Behavior`          | `StateChangeSlice`              | `Behavior_GWT` / `StateChangeSlice_GWT`                        |
| View (state projection)      | `ReadModel` + `Projection.Mapping`| `StateViewSlice`                | `Projection_GWT` / `StateViewSlice_GWT`                        |
| Automation (TODO list)       | `EventMapping` (delayed / async)  | `AutomationSlice`               | `Mapping_GWT` *(covers the Aggregate side)* / `AutomationSlice_GWT` |
| Translation (anti-corruption)| API / handler code                | `InboundTranslationSlice` / `OutboundTranslationSlice` | `InboundTranslationSlice_GWT` / `OutboundTranslationSlice_GWT` |

Two cross-cutting DSLs round out the surface:

- `Mapping_GWT` — cross-pattern automation with any combination of Aggregate or
  StateChangeSlice source/target (replaces the legacy `EventMapping_GWT` which
  ships as a backward-compat alias).
- `Query_GWT` — read-model query patterns (indexes, composite keys, resolvers)
  for both ReadModel and StateViewSlice consumers. This is the only DSL that
  asserts against `config` rather than `decide` / `evolve` / `project`.

---

## 2. Getting set up

1. Add the package as a dev dependency:
   ```json
   "devDependencies": {
     "@reventlessdev/reventless-gwt": "workspace:*"
   }
   ```
2. Declare it as a ReScript dependency in the package's `rescript.json`:
   ```json
   "bs-dev-dependencies": ["@reventlessdev/reventless-gwt"]
   ```
3. In your test file, annotate the top of the file with `@@reventless.gwt` so
   the PPX injects the right `include <Kind>_GWT.Make(<Spec>)` line. The PPX
   picks the DSL kind from the filename (substring match, longest wins:
   `AutomationSlice`, `InboundTranslationSlice`, `OutboundTranslationSlice`,
   `StateChangeSlice`, `StateViewSlice`, `Projection`, `Behavior`) and uses the
   first top-level module as the spec:
   ```rescript
   @@reventless.gwt
   ```
   Explicit forms:
   ```rescript
   @@reventless.gwt(AddCategorySlice)               // explicit Spec
   @@reventless.gwt(CategorySpec, CategoryBehavior) // Behavior DSL (two-arg functor)
   ```
   See [`.claude/rules/app-developer.md`](../../.claude/rules/app-developer.md)
   for the full PPX annotation table.

4. Run your tests:
   ```bash
   pnpm exec reventless-gwt run tests/
   ```
   During migration you can also run them under Jest — `JestBind` routes the
   same test body into either runner depending on whether the CLI collector is
   active.

---

## 3. Shared vocabulary

Every DSL uses the same verbs for the same roles:

| Verb                                  | Meaning                                         |
|---------------------------------------|-------------------------------------------------|
| `givenEvents([...])` / `givenEvent(e)`| prior events on the entity (sets up `evolve`)   |
| `whenCmd(c)`                          | dispatch a command to `decide`                  |
| `whenEvent(e)` / `whenEvents([...])`  | push an event through `project` / `map`         |
| `whenInput(i)`                        | feed external input to a translation slice      |
| `whenCollect` / `whenResolve` / `whenProcess` / `whenSweep` | automation-loop steps        |
| `thenEvent(e)` / `thenEvents([...])`  | assert `decide` emitted exactly these events    |
| `thenNoEvent` / `thenNoCommand`       | assert idempotency (nothing produced)           |
| `thenError(e)`                        | assert `decide` returned `Error(e)`             |
| `thenEventWithError(e, err)`          | `decide` returned `Ok([e])` then later errored  |
| `thenState(s)` / `thenStateWithId(id, s)` | assert the projected state for one key      |
| `thenAllStates([...])`                | assert the full projection store               |
| `thenNoState(id)`                     | assert no state exists for a key               |
| `thenRow(r)` / `thenRows([...])` / `thenRowCount(n)` | query assertion combinators       |
| `thenTodos([...])` / `thenResolved(o)`| automation TODO-list assertions                |
| `thenCommand(id, c)` / `thenCommands([...])` | commands produced by automation/translation |
| `thenAppendsConditionedOn(events, q)` / `thenAppendsConditionedOnExactly(events, cond)` | DCB optimistic-concurrency condition assertions |

Deviations from the shared vocabulary are called out per-DSL below.

---

## 4. Worked examples — one per DSL

Each example is a minimal but complete `_GWT` file that you can copy as a
template. All nine are also shipped as runnable worked-example tests in
[`reventless/reventless-gwt/tests/`](../../reventless/reventless-gwt/tests/).

### 4.1 `Behavior_GWT` — Aggregate command slice

Pure synchronous DSL. Spec module + Behavior module (two-arg functor).

```rescript
// Category aggregate command slice
open Category

include ReventlessGwt.Behavior_GWT.Make(Category, CategoryBehavior)

describe("Category Behavior", () => {
  test("Add on new aggregate produces Added", () =>
    givenEvents([])
    ->whenCmd(Add({name: "Electronics"}))
    ->thenEvent(Added({name: "Electronics"})))

  test("Add on existing aggregate returns CategoryAlreadyExists", () =>
    givenEvents([Added({name: "Electronics"})])
    ->whenCmd(Add({name: "Electronics 2"}))
    ->thenError(CategoryAlreadyExists))

  test("Archive is idempotent", () =>
    givenEvents([Added({name: "Electronics"}), Archived])
    ->whenCmd(Archive)
    ->thenNoEvent)
})
```

Real example:
[`examples/online-shop-aggregates/catalog/tests/Aggregate/CategoryBehaviorTest.res`](../../examples/online-shop-aggregates/catalog/tests/Aggregate/CategoryBehaviorTest.res).

### 4.2 `StateChangeSlice_GWT` — DCB command slice

Same vocabulary as `Behavior_GWT`, plus DCB-specific
`thenAppendsConditionedOn` / `thenAppendsConditionedOnExactly` for the
optimistic-concurrency query.

```rescript
@@reventless.gwt

module AddCategorySlice = {
  let name = "AddCategory"

  type state = {exists: bool, archived: bool}
  let initialState = {exists: false, archived: false}

  @schema type consumedEvent = CategoryAdded | CategoryArchived

  let evolve = (state, event) =>
    switch event {
    | CategoryAdded => {exists: true, archived: false}
    | CategoryArchived => {...state, archived: true}
    }

  @schema
  type command =
    AddCategory({categoryId: @s.matches(Reventless.DcbTag.string) string, name: string})

  @schema type error = CategoryAlreadyExists

  @schema
  type event =
    CategoryAdded({categoryId: @s.matches(Reventless.DcbTag.string) string, name: string})

  let decide = (state, command) =>
    switch command {
    | AddCategory({categoryId, name}) =>
      state.exists ? Error(CategoryAlreadyExists) : Ok([CategoryAdded({categoryId, name})])
    }
}

describe("AddCategory StateChangeSlice", () => {
  test("empty event log produces CategoryAdded", () =>
    givenEvents([])
    ->whenCmd(AddCategory({categoryId: "c1", name: "Electronics"}))
    ->thenEvent(CategoryAdded({categoryId: "c1", name: "Electronics"})))

  test("existing category returns CategoryAlreadyExists", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(AddCategory({categoryId: "c1", name: "X"}))
    ->thenError(CategoryAlreadyExists))

  test("append condition is single-entity query", () =>
    givenEvents([])
    ->whenCmd(AddCategory({categoryId: "c1", name: "Electronics"}))
    ->thenAppendsConditionedOn([
      {
        eventTypes: ["CategoryAdded", "CategoryArchived"],
        tags: [{key: "categoryId", value: "c1"}],
      },
    ]))
})
```

Runnable copy:
[`reventless/reventless-gwt/tests/StateChangeSliceGwtTest.res`](../../reventless/reventless-gwt/tests/StateChangeSliceGwtTest.res).

**Important:** every `@s.matches(Reventless.DcbTag.string)` annotation on the
command's ID fields is what enables the implicit `AppendConditionMismatch`
check. Forgetting it causes the GWT's DCB-query derivation to produce an
empty-tags clause; the next `then*` surfaces this as
`AppendConditionMismatch`, pointing at the command schema. See
[§9 Output format reference](#9-output-format-reference).

### 4.3 `Projection_GWT` — ReadModel projection

Async DSL with a synthetic in-memory store.

```rescript
include ReventlessGwt.Projection_GWT.Make(CategoriesProjections.CategoryMapping)

describe("Category → Categories projection", () => {
  test("Added sets the initial read model state", () =>
    givenEvents([])
    ->whenEvent(Category.Added({name: "Electronics"}))
    ->thenState({CategoriesReadModel.name: "Electronics", archived: false}))

  test("Renamed updates the name", () =>
    givenEvents([Category.Added({name: "Electronics"})])
    ->whenEvent(Category.Renamed({name: "Consumer Electronics"}))
    ->thenState({CategoriesReadModel.name: "Consumer Electronics", archived: false}))
})
```

Real example:
[`examples/online-shop-aggregates/catalog/tests/ReadModel/CategoryProjectionTest.res`](../../examples/online-shop-aggregates/catalog/tests/ReadModel/CategoryProjectionTest.res).

### 4.4 `StateViewSlice_GWT` — DCB state-view slice

Same projection shape as `Projection_GWT` but the spec owns both the
consumed-event schema and the `project` function (no separate `Mapping` module).

```rescript
@@reventless.gwt

open Reventless.Projection

module CategoriesViewSpec = {
  let name = "CategoriesView"

  @schema type state = {categoryId: string, name: string, archived: bool}

  @schema
  type consumedEvent =
    | CategoryAdded({categoryId: string, name: string})
    | CategoryRenamed({categoryId: string, name: string})
    | CategoryArchived({categoryId: string})

  let project = event =>
    switch event {
    | CategoryAdded({categoryId, name}) => [
        Set(categoryId, {categoryId, name, archived: false}),
      ]
    | CategoryRenamed({categoryId, name}) => [
        Update(categoryId, state => {...state, name}),
      ]
    | CategoryArchived({categoryId}) => [
        Update(categoryId, state => {...state, archived: true}),
      ]
    }

  let subIdConfig = None
}

describe("CategoriesView StateViewSlice", () => {
  test("CategoryAdded projects into a new row", () =>
    givenEvents([])
    ->whenEvent(CategoryAdded({categoryId: "c1", name: "Electronics"}))
    ->thenStateWithId(
      "c1",
      {categoryId: "c1", name: "Electronics", archived: false},
    ))
})
```

Runnable copy:
[`reventless/reventless-gwt/tests/StateViewSliceGwtTest.res`](../../reventless/reventless-gwt/tests/StateViewSliceGwtTest.res).

### 4.5 `Query_GWT` — ReadModel + StateViewSlice queries

The only DSL whose assertions point at `config` (indexes, composite keys,
resolvers) rather than `decide` / `project`. Works against either a ReadModel
(`FromReadModel`) or a StateViewSlice (`FromStateViewSlice`) — they share the
same `config` and `subIdConfig` surface at runtime.

```rescript
module CategoriesQuery =
  Query_GWT.Make(Query_GWT.FromReadModel(CategoriesReadModel))

CategoriesQuery.describe("Categories ReadModel queries", () => {
  CategoriesQuery.test("primary-id lookup returns the row", () =>
    CategoriesQuery.givenStore([
      ("c1", {categoryId: "c1", name: "Electronics", archived: false}),
    ])
    ->CategoriesQuery.whenQueryById("c1")
    ->CategoriesQuery.thenRow(Some({categoryId: "c1", name: "Electronics", archived: false})))

  CategoriesQuery.test("by-name (GSI) returns matching rows", () =>
    CategoriesQuery.givenStore([
      ("c1", {categoryId: "c1", name: "Electronics", archived: false}),
      ("c2", {categoryId: "c2", name: "Books", archived: true}),
    ])
    ->CategoriesQuery.whenQuery({by: "name", value: "Electronics", index: "byName"})
    ->CategoriesQuery.thenRows([{categoryId: "c1", name: "Electronics", archived: false}]))
})
```

`whenQuery` fails with `QueryRowsMismatch` when `index` is named but the
referenced entry is missing from `Spec.config.indexes`. Runnable copy:
[`reventless/reventless-gwt/tests/QueryGwtTest.res`](../../reventless/reventless-gwt/tests/QueryGwtTest.res).

### 4.6 `Mapping_GWT` — cross-pattern automation

Generalised cross-pattern automation. Source and Target can each be an
Aggregate+Behavior pair (via `FromBehavior`) or a StateChangeSlice (via
`FromStateChangeSlice`), giving all four Aggregate/DCB combinations with the
same vocabulary.

```rescript
module CategorySource   = Mapping_GWT.FromBehavior(CategorySpec, CategoryBehavior)
module ProductTarget    = Mapping_GWT.FromBehavior(ProductSpec, ProductBehavior)

module CatalogMapping = {
  module Source = CategorySource
  module Target = ProductTarget

  let map = (_sourceId, event: CategorySpec.event, _q) =>
    switch event {
    | CategoryAdded({categoryId, name}) => [
        Reventless.EventMapping.Publish(
          ("prod-for-" ++ categoryId)->ProductSpec.Id.makeFromString,
          ProductSpec.MirrorCategory({
            productId: "prod-for-" ++ categoryId, categoryId, name,
          }),
        ),
      ]
    }
}

module CatalogGwt = Mapping_GWT.Make(CatalogMapping)

CatalogGwt.describe("Category → Product (Aggr → Aggr)", () =>
  CatalogGwt.test("AddCategory produces ProductCategoryMirrored", () =>
    CatalogGwt.givenSourceEvents([])
    ->CatalogGwt.andTargetEvents([])
    ->CatalogGwt.whenSourceCmd("c1", AddCategory({categoryId: "c1", name: "Books"}))
    ->CatalogGwt.thenTargetEvent(
      "prod-for-c1",
      ProductCategoryMirrored({productId: "prod-for-c1", categoryId: "c1", name: "Books"}),
    ))
)
```

`thenTargetError`, `thenSourceError`, `thenTargetEventsWithError` are also
available for the error combinations. Swap one or both adapters to
`FromStateChangeSlice` for the DCB combinations. Runnable copies of all four
Aggregate/DCB combinations live in
[`reventless/reventless-gwt/tests/MappingGwtTest.res`](../../reventless/reventless-gwt/tests/MappingGwtTest.res).

The legacy `EventMapping_GWT.Make(Source, SourceBehavior, Target, TargetBehavior, EventMapping)`
remains callable with its old argument list — it simply composes two
`FromBehavior` adapters internally.

### 4.7 `AutomationSlice_GWT` — DCB automation

Three loop steps (`collect` / `resolve` / `process`) plus a scenario-style
`sweep`.

```rescript
@@reventless.gwt

module ShipOrderSlice = {
  let name = "ShipOrder"

  @schema
  type consumedEvent =
    | OrderPlaced({orderId: string, shippingAddress: string})
    | ShipmentCreated({orderId: string})

  @schema type todoItem = {orderId: string, shippingAddress: string}

  @schema type command = CreateShipment({orderId: string, address: string})

  let collect = event =>
    switch event {
    | OrderPlaced({orderId, shippingAddress}) => [(orderId, {orderId, shippingAddress})]
    | _ => []
    }

  let resolve = event =>
    switch event {
    | ShipmentCreated({orderId}) => Some(orderId)
    | _ => None
    }

  let process = (_id, item) =>
    Some((item.orderId, CreateShipment({orderId: item.orderId, address: item.shippingAddress})))
}

describe("ShipOrder AutomationSlice", () => {
  test("collect: OrderPlaced creates a pending TODO", () =>
    givenEvent(OrderPlaced({orderId: "o1", shippingAddress: "1 Main St"}))
    ->whenCollect
    ->thenTodos([("o1", {orderId: "o1", shippingAddress: "1 Main St"})]))

  test("resolve: ShipmentCreated marks the TODO done", () =>
    givenEvent(ShipmentCreated({orderId: "o1"}))
    ->whenResolve
    ->thenResolved(Some("o1")))

  test("process: pending TODO emits CreateShipment", () =>
    givenTodo("o1", {orderId: "o1", shippingAddress: "1 Main St"})
    ->whenProcess
    ->thenCommand("o1", CreateShipment({orderId: "o1", address: "1 Main St"})))
})
```

Runnable copy:
[`reventless/reventless-gwt/tests/AutomationSliceGwtTest.res`](../../reventless/reventless-gwt/tests/AutomationSliceGwtTest.res).

### 4.8 `InboundTranslationSlice_GWT` — external → internal translation

No `given` clause (translation is pure over its input).

```rescript
@@reventless.gwt

module PaymentWebhookSlice = {
  let name = "PaymentWebhook"

  @schema type externalInput = {paymentId: string, orderId: string, status: string}

  @schema type command = ConfirmPayment({orderId: string, paymentId: string})

  let translate = input =>
    switch input.status {
    | "completed" =>
      Ok([(input.orderId, ConfirmPayment({orderId: input.orderId, paymentId: input.paymentId}))])
    | _ => Error("Unknown payment status: " ++ input.status)
    }
}

describe("PaymentWebhook InboundTranslationSlice", () => {
  test("completed status emits ConfirmPayment", () =>
    whenInput({paymentId: "p1", orderId: "o1", status: "completed"})
    ->thenCommand("o1", ConfirmPayment({orderId: "o1", paymentId: "p1"})))

  test("unknown status surfaces translate error", () =>
    whenInput({paymentId: "p1", orderId: "o1", status: "garbage"})
    ->thenTranslateError("Unknown payment status: garbage"))
})
```

### 4.9 `OutboundTranslationSlice_GWT` — internal → external translation

Combines a `collect` pipeline (same shape as `AutomationSlice`) with a
`translate` pipeline whose actual implementation is **mocked** by the test
body — the spec's real `translate` is exercised in component callback tests
elsewhere.

```rescript
@@reventless.gwt

module SendTrackingEmailSlice = {
  let name = "SendTrackingEmail"

  @schema type consumedEvent = OrderShipped({orderId: string, email: string})
  @schema type outboundItem = {orderId: string, email: string}
  @schema type inboundCommand = NoOp

  let collect = event =>
    switch event {
    | OrderShipped({orderId, email}) => [(orderId, {orderId, email})]
    }
}

describe("SendTrackingEmail OutboundTranslationSlice", () => {
  test("collect: OrderShipped queues an outbound TODO", () =>
    givenEvent(OrderShipped({orderId: "o1", email: "x@y"}))
    ->whenCollect
    ->thenTodos([("o1", {orderId: "o1", email: "x@y"})]))

  test("translate success is fire-and-forget → #Completed", () =>
    givenTodo("o1", {orderId: "o1", email: "x@y"})
    ->whenTranslateMocked((_id, _item) => Promise.resolve(Ok(None)))
    ->thenTodoStatus("o1", #Completed))

  test("translate failure records a retry → #Pending", () =>
    givenTodo("o1", {orderId: "o1", email: "x@y"})
    ->whenTranslateMocked((_id, _item) => Promise.resolve(Error("smtp down")))
    ->thenTodoStatus("o1", #Pending))
})
```

---

## 5. The `Outcome` algebra

Every `then*` combinator returns `Outcome.outcome` (an alias for
`result<unit, Outcome.mismatch>`). The runner, the human formatter, the CI TAP
stream, the AI-generation loop, and the VS Code extension all consume the same
value — they only differ in how they render it.

`mismatch` is a closed sum of nine variants:

| Variant                     | Thrown by                                           | Default locus hint                                              |
|-----------------------------|-----------------------------------------------------|-----------------------------------------------------------------|
| `EventsMismatch`            | `thenEvent(s)` when `decide` / `map` events differ  | `{slice}.decide`                                                |
| `ErrorMismatch`             | `thenError` when `decide` returned `Ok(_)` or a different error variant | `{slice}.decide`                          |
| `StateMismatch`             | `thenState(WithId)` / `thenAllStates`               | `{slice}.evolve`                                                |
| `NoEventExpected`           | `thenNoEvent` / `thenNoCommand` when something was produced | `{slice}.decide`                                         |
| `TodoMismatch`              | `thenTodos` / `thenScenarioTodos`                   | `{slice}.collect / {slice}.resolve`                             |
| `AppendConditionMismatch`   | implicit DCB check + `thenAppendsConditionedOn*`    | `{slice}.commandSchema` — usually a missing `@s.matches(DcbTag.string)` |
| `TranslateError`            | `thenTranslateError`                                | `{slice}.translate`                                             |
| `QueryRowsMismatch`         | `thenRow(s)` / `thenRowCount` / missing-index check | `{slice}.config`                                                |
| `Throw`                     | any uncaught exception inside the DSL's pipeline    | `{slice}`                                                       |

Every failure is paired with a `Hint` record `{locus, branch, message}`. Hints
ship inside the JSON/VS Code output so downstream tools can route a fix without
re-deriving the mapping. The canonical table lives in
[`reventless-gwt/src/Hint.res`](../../reventless/reventless-gwt/src/Hint.res).

---

## 6. The CLI runner

```
reventless-gwt run      [--format=<fmt>] [--filter=<id>] [--stream] [--watch] [path...]
reventless-gwt discover [--format=vscode] [path...]
reventless-gwt watch    [--format=<fmt>] [--filter=<id>] [path...]
```

Exit code is `1` if any test failed, `0` otherwise. Path arguments default to
`tests/` — discovery finds files matching `*_GWT.res.mjs`, `*GwtTest.res.mjs`,
or `*Gwt.res.mjs` under the given roots, skipping `node_modules`, `.git`,
`lib`, and `dist`.

| Flag                    | Effect                                                                  |
|-------------------------|-------------------------------------------------------------------------|
| `--format=<fmt>`        | Pick one of `human` (default), `json`, `tap`, `junit`, `vscode`         |
| `--filter=<id>`         | Restrict execution to tests whose id contains `<id>` (repeatable)       |
| `--stream`              | NDJSON streaming variant of `json` / `vscode` (default emits a single envelope) |
| `--watch`               | Re-run on `.res.mjs` changes in the discovered roots                    |
| `--schema-version=<v>`  | Pin the JSON schema version for stable AI prompts                       |
| `--help` / `-h`         | Show help and exit                                                      |

SIGINT / SIGTERM cancel in-flight runs cleanly: the in-flight test is marked
`Skip{reason: "cancelled"}` and the runner exits with the failure count so far.

---

## 7. Output formats

| Format    | Shape                                                                          | Typical consumer                                         |
|-----------|--------------------------------------------------------------------------------|----------------------------------------------------------|
| `human`   | ANSI-coloured terminal output (auto-disabled on non-TTY). Variants rendered in ReScript syntax (`Added({name: "X"})`) instead of `{TAG: "Added", _0: ...}`. | Local development |
| `json`    | Single envelope by default, NDJSON with `--stream`. `schemaVersion: "1.0.0"`. Every value is dual-rendered as `{type, payload, rendered}`. Includes precomputed `hint` and `fieldDiff` arrays. | AI generation loop, structured CI pipelines |
| `tap`     | TAP 14 with `1..N` plan and YAML diagnostic blocks on failure.                 | `tap-spec`, `actions/test-reporter`, generic TAP tools  |
| `junit`   | `<testsuites>` / `<testsuite>` / `<testcase>` with `<failure>` bodies.         | CI dashboards, Jenkins / GitLab / Azure reporters       |
| `vscode`  | NDJSON event stream — `discoverStart` / `item` / `discoverEnd` for the tree; `runStart` / `testStart` / `testPass` / `testFail` / `testSkip` / `runEnd` for execution. Field names map 1:1 onto VS Code's `TestItem` / `TestMessage` / `TestRun` API. | `reventless-vscode` extension |

The JSON envelope documents its own shape via `schemaVersion`; consumers
downgrade by passing `--schema-version=<v>` when a field-level break ships.

---

## 8. VS Code integration

Install the `@reventlessdev/reventless-vscode` extension, open a Reventless
project, and the Testing panel populates from `reventless-gwt discover
--format=vscode`. Run/Run-with-Continuous profiles spawn `reventless-gwt run
--format=vscode --filter=<id>...` per request; cancellation forwards
`SIGINT`.

Cmd+Click on a failure jumps to the slice's implementation (`hint.locus`),
Cmd+Click on a test node jumps to the combinator's line in the original
`.res` file (not the compiled `.res.mjs`). Continuous Run keeps a run alive
and re-executes the selection whenever a `.res.mjs` under the watched roots
changes.

See [`docs/guides/reventless-vscode-testing.md`](./reventless-vscode-testing.md)
for setup, CLI path discovery, the flask-with-eye toggle, and the full manual
test checklist.

---

## 9. Output format reference

Example failure for an `AppendConditionMismatch` (most common DCB pitfall):

**Human:**
```
✗ AddCategory StateChangeSlice > empty event log produces CategoryAdded

  AppendConditionMismatch:
    expected: {"query":[{"eventTypes":["CategoryAdded","CategoryArchived"],"tags":[{"key":"categoryId","value":"c1"}]}]}
    actual:   {"query":[{"eventTypes":["CategoryAdded","CategoryArchived"],"tags":[]}]}

  hint: DCB optimistic-concurrency condition drift — likely a missing
        `@s.matches(DcbTag.string)` annotation on a command field, …
        Look at AddCategory.commandSchema.
```

**JSON (single envelope, abridged):**
```json
{
  "schemaVersion": "1.0.0",
  "summary": { "passed": 0, "failed": 1, "skipped": 0 },
  "files": [{
    "path": ".../AddCategoryGwtTest.res.mjs",
    "tests": [{
      "id": "AddCategoryGwtTest.res.mjs::AddCategory StateChangeSlice::empty event log …",
      "status": "failed",
      "mismatch": {
        "kind": "AppendConditionMismatch",
        "expected": { "query": [...] },
        "actual":   { "query": [...] }
      },
      "hint": {
        "locus": "AddCategory.commandSchema",
        "branch": null,
        "message": "DCB optimistic-concurrency condition drift — likely a missing `@s.matches(DcbTag.string)` …"
      }
    }]
  }]
}
```

Full field reference lives in
[`docs/analysis/given-when-then-specifications.md`](../analysis/given-when-then-specifications.md)
§3.3.

---

## 10. Migration tips for existing tests

- **Aggregate Behavior / ReadModel Projection** — mechanical rename:
  `ReventlessInMemory.BehaviorTest` → `ReventlessGwt.Behavior_GWT`,
  `ReventlessInMemory.ProjectionTest` → `ReventlessGwt.Projection_GWT`,
  `ReventlessInMemory.AsyncTest` → `ReventlessGwt.AsyncTest`. No logic
  changes needed.
- **DCB `*DecisionTest.res`** — structural rewrite from raw
  `expect(decide(...))->toEqual(...)` into `givenEvents`/`whenCmd`/`thenEvent`
  form. For small surfaces do it by hand; for hundreds of files the analysis
  doc §5.4 sketches an LLM-assisted rewrite where you verify the new GWTs
  against unchanged production code.
- **`EventMappingTest`** — rename to `EventMapping_GWT` (backward-compat
  alias) or, for new work, adopt `Mapping_GWT` directly and drop down to
  explicit `FromBehavior` / `FromStateChangeSlice` adapters.
- **Cross-plugin E2E tests** — stay as-is. They dispatch real commands
  through the in-memory bus and assert on emitted events; they're integration
  tests, not GWTs. The runner doesn't try to consume them.
- **Stage dependency** — tests continue to work under Jest during migration
  because `JestBind` routes to either runner based on `Collector.isActive()`.
  You can move one package at a time.
- **PPX annotation** — once a file's `include <Kind>_GWT.Make(<Spec>)` is
  stable, replace it with `@@reventless.gwt` at the top and let the PPX
  infer the kind. See
  [`.claude/rules/app-developer.md`](../../.claude/rules/app-developer.md)
  for the full attribute form.

---

## 11. Related documentation

- [`docs/analysis/given-when-then-specifications.md`](../analysis/given-when-then-specifications.md) —
  design rationale, alternatives, and the canonical format / hint-table
  specifications.
- [`docs/guides/component-testing-guide.md`](./component-testing-guide.md) —
  where Jest-based component / integration tests live (not the slice level).
- [`docs/guides/reventless-vscode-testing.md`](./reventless-vscode-testing.md) —
  VS Code extension setup, continuous run, troubleshooting.
- [`docs/guides/aggregate-vs-dcb-decision-guide.md`](./aggregate-vs-dcb-decision-guide.md) —
  when to reach for an Aggregate and when a StateChangeSlice.
- [`.claude/rules/app-developer.md`](../../.claude/rules/app-developer.md) —
  full PPX annotation reference (including `@@reventless.gwt` payload forms).
