# Given-When-Then Specifications in Reventless

> **Status:** Implemented as of 2026-04-24 — see
> [`docs/plans/done/reventless-gwt.md`](../plans/done/reventless-gwt.md) for
> the phased rollout record (Stages 1–9, 11, 12 all landed; Stage 10 is this
> file plus [`docs/guides/given-when-then.md`](../guides/given-when-then.md)).
> This document preserves the design rationale, alternatives considered, and
> canonical format / hint-table specifications; the day-to-day usage guide is
> [`docs/guides/given-when-then.md`](../guides/given-when-then.md).

Analysis of the framework's Given-When-Then (GWT) specification support for Event Modeling slices, the gaps between Aggregate-side and DCB-side test DSLs, the case for a single Reventless-owned testing package replacing Jest for GWT files, and how far AI-assisted generation of implementation + tests from a GWT corpus can go.

---

## 1. What Event Modeling expects from a GWT layer

Event Modeling, as captured in [`event-modeling-comparison.md`](./event-modeling-comparison.md), reduces every information system to four slice patterns. Each pattern has a canonical Given-When-Then shape:

| Slice | Given | When | Then |
|-------|-------|------|------|
| **Command (state-change)** | prior events on the entity | command issued | new event(s) emitted, OR an error |
| **View (state-view)** | prior events | view queried (or projection invoked) | rows returned / state shape |
| **Automation (TODO list / processor)** | events that build the TODO list | a tick / new event arrives | command(s) issued, TODO marked done |
| **Translation (anti-corruption)** | external input OR domain events | translator runs | command(s) emitted to internal system OR external call made |

The framework's component model mirrors this 1:1:

| Pattern | Aggregate world | DCB world |
|---------|-----------------|-----------|
| Command | `Aggregate` + `Behavior` | `StateChangeSlice` |
| View | `ReadModel` + `Projection.Mapping` | `StateViewSlice` |
| Automation | `EventMapping` (publish/publishDelayed/publishAsync) | `AutomationSlice` |
| Translation (in) | API/handler code | `InboundTranslationSlice` |
| Translation (out) | `SideEffectHandler` | `OutboundTranslationSlice` |

A complete GWT layer needs a DSL for **every cell of that table**, with consistent shape so the same example can be expressed the same way regardless of which architectural style the slice is implemented in. Read models additionally need a separate dimension — query patterns — that a projection-only DSL cannot capture.

---

## 2. Current state and gaps

All three existing DSLs live in [`reventless-core/tests/`](../../reventless/reventless-core/tests/), with near-duplicates of `BehaviorTest`/`ProjectionTest`/`AsyncTest` in [`reventless-in-memory/src/test/`](../../reventless/reventless-in-memory/src/test/).

### 2.1 [BehaviorTest](../../reventless/reventless-core/tests/BehaviorTest.res) — Aggregate command slice

Pure synchronous DSL. Functor over `(Spec, Behavior)`:

```rescript
include ReventlessInMemory.BehaviorTest.Make(Category, CategoryBehavior)

test("on new aggregate produces Added", () =>
  givenEvents([])
  ->whenCmd(Add({name: "Electronics"}))
  ->thenEvent(Added({name: "Electronics"})))
```

Combinators: `givenEvents`, `whenCmd`, `thenEvent`, `thenEvents`, `thenNoEvent`, `thenError`, `thenEventWithError`, `thenCompareEvent(s)`. Errors captured in a module-level `ref` and asserted alongside events.

Strengths: idiomatic, matches Behavior shape exactly, no async overhead.
Limitations: only one entity stream; no notion of multiple `id`s in the history.

### 2.2 [EventMappingTest](../../reventless/reventless-core/tests/EventMappingTest.res) — Aggregate→Aggregate automation

Async DSL composing two aggregates and one `EventMapping`. Functor over `(Source, SourceBehavior, Target, TargetBehavior, EventMapping)`:

```rescript
givenSourceEvents([CategoryArchived(...)])
->givenTargetEvents([("p-1", [ProductAdded(...)])])
->whenSourceCmd("c-1", ArchiveCategory(...))
->thenTargetEvent("p-1", ProductArchived(...))
```

Strengths: covers cross-aggregate flow including the QueryEngine stub; respects target-aggregate behavior so target invariants are enforced.
Limitations: only `Aggregate→Aggregate`; no support for `PublishDelayed` time travel; `thenTargetError` family commented out, never finished; no integration with DCB sources or targets.

### 2.3 [ProjectionTest](../../reventless/reventless-core/tests/ProjectionTest.res) — ReadModel projection

Async DSL with a synthetic in-memory store. Functor over `Projection.Mapping`:

```rescript
givenEvents([CategoryAdded(...)])
->whenEvent(CategoryRenamed(...))
->thenState({categoryId: "c1", name: "Consumer Electronics", archived: false})
```

Combinators: `givenEvents(WithTime)`, `whenEvent(s)(WithTime)`, `thenState(s)`, `thenStateWithId`, `thenAllStates`, `thenNoState`, `thenThrow`, `thenFail`. Honors `subIdConfig` for composite-key tables and exercises `Projection.handleActions` against the full save/load/delete adapter shape.

Strengths: most complete DSL — supports time, sub-IDs, multi-state, all `Projection.action` variants.
Limitations: drives one mapping at a time. Multi-source projections must be tested independently. Does not address read model **query patterns** (indexes, resolvers, subId config).

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

Boilerplate-heavy, hand-evolved state, no `givenEvents` (state built directly with the constructor record), no `thenError` semantics, no parallel to the GWT vocabulary. Same shape for `StateViewSlice`. DCB E2E tests dispatch real commands through the in-memory bus and count emitted events — useful integration tests but not GWTs.

### 2.5 Coverage matrix

| Slice / Concern | Has DSL? | GWT vocab | DCB-aware |
|---|---|---|---|
| Aggregate Behavior | yes (`BehaviorTest`) | yes | n/a |
| Aggregate→Aggregate automation | yes (`EventMappingTest`) | partial — error then commented out | n/a |
| ReadModel projection | yes (`ProjectionTest`) | yes | n/a |
| ReadModel queries | **no** | n/a | n/a |
| StateChangeSlice | **no** — hand-rolled | no | needs DCB tag awareness |
| StateViewSlice | **no** — hand-rolled | no | needs DCB event awareness |
| AutomationSlice | **no** | no | needs collect/resolve/process loop |
| InboundTranslationSlice | **no** | no | needs translate semantics |
| OutboundTranslationSlice | **no** | no | needs translate + retry semantics |
| Cross-pattern automation (Aggregate↔DCB) | **no** | no | needs dual-source handling |

### 2.6 Duplication and inconsistency audit

The three existing DSLs were written at different times and accreted different shapes:

| Concern | `BehaviorTest` | `EventMappingTest` | `ProjectionTest` |
|---|---|---|---|
| Async? | sync | async | async |
| Test runner call | `Jest.test` | `Jest.testPromise` | `Jest.testPromise` |
| Return type of `then*` | `Jest.assertion` | `promise<Jest.assertion>` | `promise<Jest.assertion>` |
| Return type of `when*` | `array<event>` | `promise<dict<...>>` | `Jest.Expect.plainPartial<unit => promise<store>>` |
| State storage | module-level `ref` for errors | per-aggregate module-level `ref` | none — store passed through chain |
| Concurrency safety | races (per MEMORY) | races on shared error refs | safe — store is local |
| `describeWithId` variant | no | no | yes |
| `*WithTime` variants | no | no | yes |
| Error-path combinators | full set | **commented out** | partial (`thenThrow`, `thenFail`) |
| Idempotency assertion | `thenNoEvent` | `thenNoTargetEvent` | `thenNoState` |
| `Spec` parameterisation | `Behavior.Spec` (rich) | `Aggregate.Spec` (rich) | `Projection.Mapping` (only sourceEvent + targetState) |
| Duplicated module | `reventless-in-memory/src/test/BehaviorTest.res` | not duplicated | `reventless-in-memory/src/test/ProjectionTest.res` |

Rough summary of what needs fixing:

1. **One vocabulary.** Standardise on `givenEvents`, `whenCmd`/`whenEvent`/`whenInput`/`whenSweep`, `thenEvent(s)`/`thenError`/`thenState(s)`/`thenCommand(s)`/`thenNo*`. Document the verb table once.
2. **Drop the module-level `errors` ref.** Both `BehaviorTest` and `EventMappingTest` share state across concurrent tests (MEMORY documents the `testPromise` race). Bundle results into the value passed through the chain.
3. **Unify the chain shape.** The mix of synchronous chained value (`array<event>`), `promise<state>`, and `Jest.Expect.plainPartial<unit => promise<store>>` is the main source of cognitive load. Pick one — synchronous chained value where possible; `promise<chainState>` for inherently async DSLs.
4. **Finish the error combinators in `EventMapping_GWT`.** The commented-out `thenTargetError`, `thenTargetEventsWithError` are still missing.
5. **Promote `describeWithId` and `*WithTime`** to all DSLs — useful in every context.
6. **Standardise `Spec` parameterisation.** Every Make functor takes `(Spec, Behavior?)` directly. Improves both human reading and AI generation.
7. **Delete the `reventless-in-memory/src/test/*` copies.** They exist purely to dodge a `@send external` resolution issue across packages — see §6.1.1.

---

## 3. Target architecture

The proposal is to consolidate every GWT concern — DSLs, the runner-agnostic `Outcome` algebra, the CLI runner, and any optional Jest adapter — into **one** new package called `reventless-gwt`. This section spells out why one package, what's in the `Outcome` algebra, and what the CLI looks like.

### 3.1 One package: `reventless-gwt`

#### Why one package and not two

An earlier draft of this proposal split the work across two packages: `reventless-spec-test` for the DSLs and `reventless-gwt` for the runner. The split is more organizational than technical:

- The runner's `Bind` module shares a module-level `Collector` with the DSLs — they cannot live behind opaque package boundaries without exposing the collector.
- No realistic consumer wants only the DSLs without a runner, or the runner without DSLs.
- Users who write `_GWT.res` files import `Behavior_GWT.Make(...)` *and* `Bind` from the same set of dependencies. Splitting forces two `package.json` entries that always move together.

So `reventless-gwt` ships everything: the DSLs, the `Outcome` algebra, the CLI runner, an optional Jest adapter, and the `AsyncTest` Jest-binding helper kept for non-GWT tests.

#### Why a separate package and not folded into `reventless-spec`

The slice **spec** module types (`Behavior`, `StateChangeSlice`, `StateViewSlice`, `AutomationSlice`, `Inbound/OutboundTranslationSlice`, `EventMapping`, `Projection.Mapping`, `ReadModel`) all live in `reventless-spec`. Folding the GWT layer in alongside is technically possible but undesirable:

| Concern | Keep `reventless-spec` pure | Fold GWT in |
|---|---|---|
| Dependencies | `sury` only | `sury` + `chokidar` + `picocolors` + a Node bin entry |
| Identity | "type definitions for the framework" | "types AND a CLI test runner" |
| Production import surface | tiny | grows with watch-mode/runner code |
| Layer coupling | spec is unimported by anyone who isn't writing slices | spec is unimported by anyone who isn't writing slices OR running tests |

A separate `reventless-gwt` package keeps `reventless-spec` runtime-free in a meaningful sense and lets test tooling evolve without bumping the spec.

#### Three placement variants we considered

| Variant | DSLs | Runner | Jest dep | Verdict |
|---|---|---|---|---|
| **A** (DSLs in spec) | `reventless-spec/src/test/` | separate `reventless-gwt` | none | spec accretes test responsibility |
| **B** (Jest peer-dep on spec) | `reventless-spec/src/test/` | bound to Jest in spec | yes (peer) | couples spec to a single runner — discarded |
| **C** (single test package) | `reventless-gwt/src/` | same package | optional adapter | recommended |

C wins for the same reasons one package wins over two: minimum coupling, minimum import friction, no duplicated state across package boundaries.

#### App-developer experience

```
examples/online-shop-aggregates/catalog/
├─ src/
│  └─ Aggregate/
│     └─ Category/
│        ├─ Category.res            # @@reventless.spec
│        └─ CategoryBehavior.res    # @@reventless.behavior
└─ tests/
   └─ Aggregate/
      └─ Category/
         └─ CategoryBehavior_GWT.res   # the GWT spec
```

`CategoryBehavior_GWT.res`:

```rescript
include ReventlessGwt.Behavior_GWT.Make(Category, CategoryBehavior)
include ReventlessGwt.Bind   // binds describe/test to the CLI runner

describe("CategoryBehavior", () => {
  test("Add on new aggregate produces Added", () =>
    givenEvents([])
    ->whenCmd(Add({name: "Electronics"}))
    ->thenEvent(Added({name: "Electronics"})))
})
```

`package.json`:

```json
{
  "dependencies": { "@reventlessdev/reventless-spec": "*" },
  "devDependencies": {
    "@reventlessdev/reventless-gwt": "*"
  }
}
```

Two include lines. Run with `pnpm exec reventless-gwt run`.

To run under Jest instead, the second `include` becomes `ReventlessGwt.JestBind` and `pnpm test` works as before. The DSL line is unchanged.

### 3.2 The `Outcome` algebra

Every GWT combinator returns a structured `Outcome.outcome` rather than a `Jest.assertion`. This is the load-bearing decoupling: the runner, the human formatter, the AI loop, and the IDE all consume the same `Outcome` value, just rendered differently.

```rescript
// reventless-gwt/src/Outcome.res
type mismatch =
  | EventsMismatch({expected: array<JSON.t>, actual: array<JSON.t>})
  | ErrorMismatch({expected: JSON.t, actual: option<JSON.t>})
  | StateMismatch({key: string, expected: JSON.t, actual: option<JSON.t>})
  | NoEventExpected({actual: array<JSON.t>})
  | TodoMismatch({expected: array<(string, JSON.t)>, actual: array<(string, JSON.t)>})
  | AppendConditionMismatch({expected: DcbTag.appendCondition, actual: DcbTag.appendCondition})
  | TranslateError({expected: string, actual: option<string>})
  | QueryRowsMismatch({expected: array<JSON.t>, actual: array<JSON.t>})
  | Throw({error: string, stack: string})

type outcome = result<unit, mismatch>
```

Each `then*` combinator returns `Outcome.outcome`. The `Bind` module owns a `Collector` that pushes `(testName, outcome)` pairs into a module-level array as test files execute. The CLI drains the collector after each file and dispatches to a formatter.

Each mismatch variant maps to a specific fix locus, used by both the human formatter and the AI loop:

| Mismatch | Likely fix locus |
|---|---|
| `EventsMismatch` | `decide` — wrong event payload or count |
| `ErrorMismatch` | `decide` — wrong error variant or missing branch |
| `StateMismatch` | `evolve` — wrong fold or missing branch |
| `NoEventExpected` | `decide` — emitted events when it shouldn't have (idempotency miss) |
| `TodoMismatch` | `collect`/`resolve` — automation diverged |
| `AppendConditionMismatch` | `commandSchema` — missing `@s.matches(DcbTag.string)` annotation |
| `TranslateError` | `translate` — translation result wrong |
| `QueryRowsMismatch` | read model `config` — missing index, sub-id, or resolver |
| `Throw` | the slice raised an exception |

Each mismatch optionally carries a source-location hint (filename + line number, captured at `then*` call time via a PPX or via `Js.Error.stackTrace` parsing). The Hint module is the single source of truth for the `(kind, locus, branch, message)` mapping.

### 3.3 The `reventless-gwt` CLI runner

#### Why drop Jest for GWT files

Jest does very little for GWT files that the framework can't do better with knowledge of its own types, and it has two persistent friction points:

1. **Jest only knows JavaScript values.** A ReScript variant `CategoryAdded({categoryId: "c1", name: "X"})` reaches Jest as the JS object `{TAG: "CategoryAdded", _0: {categoryId: "c1", name: "X"}}`. When `expect(...)->toEqual(...)` fails, Jest's diff prints the JS shape with `TAG`/`_0` field names — every test author has to mentally translate on every failure.
2. **Jest's structural equality is opaque.** When two events differ at one nested field, Jest's diff doesn't know that the type is `Spec.event`. The Outcome algebra already carries the typed mismatch with sury schemas in scope, so a Reventless-owned renderer can show ReScript syntax, highlight the differing field, and point at the function to fix.

The CLI keeps Jest available as one optional output adapter for teams that want it. Non-GWT tests (component integration, infrastructure, in-memory bus) continue to use Jest unchanged.

#### Single CLI, multiple output formats

```
reventless-gwt run [files...]                       # default: human-readable, exit 1 on failure
reventless-gwt run --format=json [files...]         # AI-loop mode: structured JSON envelope
reventless-gwt run --format=json --stream           # AI-loop streaming: NDJSON
reventless-gwt run --format=tap [files...]          # generic CI: TAP 14
reventless-gwt run --format=junit [files...]        # legacy CI: JUnit XML
reventless-gwt run --format=vscode [files...]       # IDE: NDJSON event stream for VS Code Test API
reventless-gwt discover --format=vscode [files...]  # IDE: tree population without execution
reventless-gwt watch [files...]                     # human + bun-style hot reload
reventless-gwt run --filter=<id> [files...]         # name-filtered subset
reventless-gwt run --schema-version=1.0.0 [...]     # pin output contract for stable AI prompts
```

All formats consume the same in-memory list of `(name, Outcome.outcome)` pairs produced by the GWT files. They differ only in how the renderer walks each `Mismatch` variant.

#### Human format

The human formatter walks each value's sury schema and reverse-renders to ReScript syntax. The Hint module supplies a one-line locus pointer.

```
✗ CategoryBehavior_GWT.res:18  rejects when category already exists

  expected:  Error(CategoryAlreadyExists)
  actual:    Ok([
               CategoryAdded({
                 categoryId: "c1",
                 name: "Electronics",   // ← only field that differs
               }),
             ])

  given:     [Added({name: "Electronics"})]
  when:      Add({name: "Electronics 2"})

  hint: decide() returned Ok([...]) but the test expected Error.
        Look at CategoryBehavior.res's `decide` branch for `(Active(_), Add(_))`.
```

Compare to today's Jest output for the same failure:

```
expect(received).toEqual(expected)

  - Object { "TAG": "Error", "_0": "CategoryAlreadyExists" }
  + Object { "TAG": "Ok", "_0": Array [
      Object { "TAG": "CategoryAdded", "_0": Object {
        "categoryId": "c1", "name": "Electronics" } } ] }
```

Three wins: ReScript syntax (constructor names not `TAG`/`_0`), field-level diff (sury-walked, not JSON-walked), locus hint (precomputed by `Hint.res`).

#### JSON format

The JSON format is the AI loop's primary input and the substrate for any tool that wants programmatic access (IDE extensions, dashboards, custom CI checks). Designed for **stability** (versioned schema), **completeness** (every field that contributed to the failure), and **streamability** (one JSON object per test on stdout, or a single envelope at the end).

##### Top-level envelope

```json
{
  "schemaVersion": "1.0.0",
  "tool": "reventless-gwt",
  "toolVersion": "0.1.0",
  "startedAt": "2026-04-23T14:32:11.413Z",
  "durationMs": 287,
  "summary": {"total": 14, "passed": 12, "failed": 1, "skipped": 1, "files": 3},
  "files": [
    {
      "path": "examples/.../CategoryBehavior_GWT.res",
      "tests": [ /* test results */ ]
    }
  ]
}
```

`schemaVersion` is mandatory — bumping it is a breaking change for any LLM prompt or downstream tool. Treat it like a public API.

##### Per-test result — pass

```json
{
  "id": "CategoryBehavior::Add::on new aggregate produces Added",
  "name": "on new aggregate produces Added",
  "describePath": ["CategoryBehavior", "Add"],
  "status": "pass",
  "durationMs": 0.8,
  "location": {"file": "CategoryBehavior_GWT.res", "line": 12, "column": 5}
}
```

`id` is a stable, dot-separated path that survives test reordering — the AI loop and the IDE use it to correlate fixes across iterations.

##### Per-test result — fail

```json
{
  "id": "CategoryBehavior::Add::rejects when category already exists",
  "name": "rejects when category already exists",
  "describePath": ["CategoryBehavior", "Add"],
  "status": "fail",
  "durationMs": 1.2,
  "location": {"file": "CategoryBehavior_GWT.res", "line": 18, "column": 5},
  "scenario": {
    "given": {
      "events": [
        {"type": "Added", "payload": {"name": "Electronics"},
         "rendered": "Added({name: \"Electronics\"})"}
      ]
    },
    "when": {
      "kind": "command",
      "value": {"type": "Add", "payload": {"name": "Electronics 2"},
                "rendered": "Add({name: \"Electronics 2\"})"}
    }
  },
  "mismatch": {
    "kind": "ErrorMismatch",
    "expected": {"type": "CategoryAlreadyExists", "payload": null,
                 "rendered": "Error(CategoryAlreadyExists)"},
    "actual": null,
    "actualEvents": [
      {"type": "CategoryAdded",
       "payload": {"categoryId": "c1", "name": "Electronics"},
       "rendered": "CategoryAdded({categoryId: \"c1\", name: \"Electronics\"})",
       "fieldDiff": [
         {"path": "name", "expected": "(none — error expected)", "actual": "\"Electronics\""}
       ]}
    ],
    "hint": {
      "locus": "CategoryBehavior.decide",
      "branch": "(Active(_), Add(_))",
      "message": "decide() returned Ok([...]) but the test expected Error."
    }
  }
}
```

Three deliberate properties:

1. **Every value is dual-rendered.** `type` + `payload` for programmatic consumption *and* `rendered` for human/LLM reading in ReScript syntax.
2. **`scenario` is always present on failures.** The `given` and `when` payloads are captured at chain-execution time so the failure is self-contained.
3. **`hint` is precomputed.** Same data as the human formatter, ready to drop into prompts or VS Code messages.

##### Mismatch variant shapes

| `kind` | Required additional fields | Use |
|---|---|---|
| `EventsMismatch` | `expected: array<value>`, `actual: array<value>`, `fieldDiff: array<diff>` | wrong event count or payload |
| `ErrorMismatch` | `expected: value`, `actual: value\|null`, `actualEvents: array<value>` | wrong error variant or missing branch |
| `StateMismatch` | `key: string`, `expected: value\|null`, `actual: value\|null`, `fieldDiff` | projection produced wrong state |
| `NoEventExpected` | `actual: array<value>` | idempotency assertion failed |
| `TodoMismatch` | `expected: array<{id,value}>`, `actual: array<{id,value}>`, `fieldDiff` | automation collect/process diverged |
| `AppendConditionMismatch` | `expected: appendCondition`, `actual: appendCondition` | DCB optimistic-concurrency contract drift |
| `TranslateError` | `expected: string`, `actual: string\|null` | translation result wrong |
| `QueryRowsMismatch` | `expected: array<value>`, `actual: array<value>`, `fieldDiff` | read model query returned wrong rows |
| `Throw` | `error: string`, `stack: string` | the slice threw an exception |

A `value` is always `{type: string, payload: any|null, rendered: string}`. A `diff` is always `{path: string, expected: any, actual: any}`. The schema is closed — consumers can switch on `kind`.

##### Streaming variant

`--format=json --stream` emits NDJSON (one object per line):

```
{"type":"runStarted","schemaVersion":"1.0.0","at":"2026-04-23T..."}
{"type":"fileStarted","path":"...CategoryBehavior_GWT.res"}
{"type":"testResult", ... }
{"type":"fileFinished","path":"...","passed":3,"failed":1}
{"type":"runFinished","summary":{...}}
```

This lets the AI loop start synthesizing fixes before the suite finishes. Default (`--format=json` without `--stream`) is the single-envelope shape.

##### Versioning policy

- `schemaVersion: 1.x.x` — additive changes only (new optional fields, new mismatch kinds).
- `schemaVersion: 2.0.0` — breaking changes; forces every consumer (LLM prompts, IDE extensions) to opt in.
- `--schema-version` flag downgrades output to a prior schema. Lets old prompts keep working while the schema evolves.

#### TAP format

[TAP (Test Anything Protocol)](https://testanything.org/) is the lingua franca of CI test reporting. Reventless targets **TAP 14** (current spec, supports YAML diagnostics for failure detail).

```
TAP version 14
1..14

# CategoryBehavior_GWT.res
ok 1 - CategoryBehavior > Add > on new aggregate produces Added # time=0.8ms
not ok 2 - CategoryBehavior > Add > rejects when category already exists # time=1.2ms
  ---
  kind: ErrorMismatch
  location: { file: CategoryBehavior_GWT.res, line: 18 }
  scenario:
    given: [ "Added({name: \"Electronics\"})" ]
    when: "Add({name: \"Electronics 2\"})"
  expected: "Error(CategoryAlreadyExists)"
  actual: "Ok([CategoryAdded({categoryId: \"c1\", name: \"Electronics\"})])"
  fieldDiff:
    - { path: name, expected: "(none — error expected)", actual: "\"Electronics\"" }
  hint:
    locus: "CategoryBehavior.decide"
    branch: "(Active(_), Add(_))"
    message: "decide() returned Ok([...]) but the test expected Error."
  ...
ok 3 - CategoryBehavior > Rename > on non-existent aggregate returns CategoryNotFound # time=0.4ms
ok 4 - CategoryBehavior > Rename > on active category produces Renamed # SKIP filtered out

# OrderBehavior_GWT.res
# Subtest: PlaceOrder
    1..3
    ok 1 - on non-existent order produces OrderPlaced
    ok 2 - on existing order returns OrderAlreadyPlaced
    ok 3 - idempotent on duplicate
ok 5 - PlaceOrder

# tests 14
# pass 12
# fail 1
# skip 1
```

Key features: TAP 14 plan line (`1..14`), rendered values in YAML diagnostic blocks (already ReScript syntax — CI logs show `Ok([CategoryAdded({...})])` not JS shapes), subtests for `describe` blocks, `# time=...ms` directives, `# SKIP <reason>`, file-grouping comments.

##### Why TAP and not just JUnit XML

Both are supported (`--format=junit` exists), but TAP is preferable for several reasons:

- **Streaming-native.** TAP emits one line at a time; JUnit XML wraps everything in `<testsuite>` and is batch-only.
- **Human-readable on a dumb terminal.** `tail -f` works on TAP; JUnit XML is impenetrable.
- **Standard tool ecosystem.** `tap-mocha-reporter`, `tap-spec`, `tap-summary` all work out of the box. Pipe `reventless-gwt run --format=tap | tap-spec` for instant pretty output.
- **Structured YAML diagnostics.** Unlike JUnit's `<failure message="...">` (one string), TAP's YAML block is structured. Reporters can extract `expected`/`actual`/`fieldDiff` and render them properly.
- **Trivial to convert.** TAP → JUnit is a 50-line shell script. The reverse is lossy.

##### TAP consumers

- **GitHub Actions**: native annotations via [`actions/test-reporter`](https://github.com/dorny/test-reporter).
- **GitLab CI**: TAP via [`tap-junit`](https://www.npmjs.com/package/tap-junit) or direct.
- **Jenkins**: [TAP plugin](https://plugins.jenkins.io/tap/) ingests directly.
- **CircleCI**: standard test results uploader.
- **Local dev**: `pnpm exec reventless-gwt run --format=tap | tap-spec`.

##### Combined output for hybrid pipelines

`--format=tap+json` writes TAP to stdout (live CI logs) and JSON to a side file (`reventless-gwt.results.json`) for downstream tooling.

#### VS Code format

`--format=vscode` is an NDJSON event stream tailored for the [VS Code Testing API](https://code.visualstudio.com/api/extension-guides/testing). It differs from `--format=json --stream` in three ways: it includes **discovery events** (so the test tree populates before any test runs), **per-test lifecycle events** (`testStart` so the spinner shows up), and **fields named for direct mapping to `TestController`/`TestItem`/`TestMessage`** without any translation layer in the extension.

##### Three invocation modes

```bash
reventless-gwt discover --format=vscode [files...]   # populate the tree, no execution
reventless-gwt run --format=vscode [--filter=<id>...] [files...]   # execute and stream results (one-shot)
reventless-gwt watch --format=vscode [--filter=<id>...] [files...] # long-lived: discover + build + run + re-run
```

With **no `files...`** the CLI auto-discovers GWT tests across the whole cwd subtree (pruning
`node_modules`/`lib`/`.git`/`.history`), so the extension passes only the workspace folder as cwd — no
roots configuration. `watch` is the engine the extension drives: it emits the discovery stream once, then
owns a `rescript build -w` per package and re-runs on every recompile. Discovery is fast (compile + load
only, no test bodies executed) so the tree populates immediately on open.

##### Protocol handshake

Every `--format=vscode` invocation emits a `hello` line first so a client can detect a version-skewed CLI
and ignore unknown events:

```
{"event":"hello","protocol":2}
```

Protocol 2 added the `components` inventory event and the `component` field on file `item`s (Plugin → kind →
component grouping); a protocol-1 client simply ignores both.

##### Discovery stream

```
{"event":"discoverStart"}
{"event":"item","id":"CategoryBehavior_GWT.res","kind":"file","label":"CategoryBehavior_GWT.res","uri":"file:///.../CategoryBehavior_GWT.res","component":{"kind":"Aggregate","name":"Category"}}
{"event":"item","id":"CategoryBehavior_GWT.res::CategoryBehavior","parent":"CategoryBehavior_GWT.res","kind":"suite","label":"CategoryBehavior","range":{"start":{"line":7,"character":0},"end":{"line":78,"character":1}}}
{"event":"item","id":"...CategoryBehavior::Add","parent":"...CategoryBehavior","kind":"suite","label":"Add","range":{"start":{"line":8,"character":2},"end":{"line":24,"character":3}}}
{"event":"item","id":"...Add::on new aggregate produces Added","parent":"...Add","kind":"test","label":"on new aggregate produces Added","range":{"start":{"line":10,"character":4},"end":{"line":14,"character":5}}}
{"event":"discoverEnd","total":14}
```

Each `item` event carries the exact fields a VS Code extension needs: `id` (used as `TestItem.id`), `parent` (for nesting), `kind` (`file`/`suite`/`test`), `label`, `uri` + `range` (for jump-to-source). File items additionally carry `component` (`{kind, name}` derived from the folder convention) so a client groups tests by Plugin → component without parsing source.

##### Run stream

```
{"event":"runStart","total":14,"filter":["...CategoryBehavior::Add"]}
{"event":"testStart","id":"...Add::on new aggregate produces Added"}
{"event":"testPass","id":"...Add::on new aggregate produces Added","durationMs":0.8}
{"event":"testStart","id":"...Add::rejects when category already exists"}
{"event":"testFail","id":"...Add::rejects when category already exists","durationMs":1.2,"messages":[{"message":"decide() returned Ok([...]) but the test expected Error.","expected":"Error(CategoryAlreadyExists)","actual":"Ok([CategoryAdded({categoryId: \"c1\", name: \"Electronics\"})])","location":{"uri":"file:///.../CategoryBehavior.res","range":{"start":{"line":34,"character":2},"end":{"line":40,"character":3}}}}]}
{"event":"testSkip","id":"...Add::idempotent on duplicate","reason":"filtered"}
{"event":"runEnd","passed":12,"failed":1,"skipped":1,"durationMs":287}
```

Each event maps **directly** to a [`TestRun`](https://code.visualstudio.com/api/references/vscode-api#TestRun) method call:

| CLI event | Extension call |
|---|---|
| `runStart` | `controller.createTestRun(...)` |
| `testStart` | `run.started(testItem)` |
| `testPass` | `run.passed(testItem, durationMs)` |
| `testFail` | `run.failed(testItem, new TestMessage(...), durationMs)` — `expected`/`actual` set on `TestMessage` for the diff view |
| `testSkip` | `run.skipped(testItem)` |
| `runEnd` | `run.end()` |

##### Watch stream — `packages` + `build*` events

`watch` additionally emits the derived build set and per-package build status. The `packages` event lists
every workspace package owning tests (walked up from the discovered files to the nearest `package.json`
with a `start` script), and `build*` events report each managed `rescript build -w`:

```
{"event":"packages","packages":[{"name":"@reventlessdev/online-shop-hybrid-catalog","dir":"/abs/catalog","build":"rescript build -w"}]}
{"event":"buildStart","package":"/abs/catalog"}
{"event":"buildOk","package":"/abs/catalog","durationMs":361}
{"event":"buildFail","package":"/abs/catalog","message":"…/Category.res:24 This has type: string\nBut it's expected to have type: int"}
{"event":"buildExternal","package":"/abs/ordering"}   // a developer's own `rescript build -w` already holds the lock — adopted, not duplicated
```

| CLI event | Extension call |
|---|---|
| `packages` | record the build set (status-bar grouping) |
| `buildStart` / `buildOk` / `buildFail` | status-bar state + "Reventless GWT — Build" output channel |
| `buildExternal` | mark the package as covered by the user's own watcher |
| `components` | full component inventory → activity-bar Plugin→kind→component tree + "untested slice" signal |

`discover` and `watch` also emit a `components` event: the full set of components found in each owning
package's `src/` (by folder convention — Aggregate / StateChangeSlice / ReadModel / …), **including
components with no GWT tests**. `dir` matches the `packages` event so a client joins them per plugin; tests
join via the `component` field on each file `item`. The difference (components present vs components with a
test file) is the coverage signal.

```
{"event":"components","components":[{"dir":"/abs/catalog","kind":"Aggregate","name":"Category"},{"dir":"/abs/catalog","kind":"ReadModel","name":"CatalogActivity"}]}
```

The CLI owns the watchers (spawn, classify output, tear down on SIGINT via its process group); the extension
only renders. Conflict avoidance lives CLI-side: `buildExternal` is emitted when `lib/rescript.lock` holds a
live PID, so the extension never double-spawns. The whole `watch` run is one long-lived process — each
internal re-run produces a fresh `runStart`…`runEnd` cycle.

Three deliberate choices for `testFail`:

1. **`messages` is an array.** VS Code allows multiple `TestMessage`s per test (one per failed `then*`).
2. **`location` points at the *implementation* file**, not the test file. Cmd+Click on a failure jumps to `CategoryBehavior.decide`'s `(Active, Add)` branch — not back to the test that just passed/failed.
3. **`expected`/`actual` are pre-rendered ReScript syntax.** VS Code's diff view renders arbitrary string diffs side-by-side, so it shows `Error(CategoryAlreadyExists)` vs `Ok([CategoryAdded({...})])` rather than `{TAG:"Error",_0:...}`.

##### The thin VS Code extension

```typescript
// reventless-vscode/src/extension.ts
const controller = vscode.tests.createTestController('reventless-gwt', 'Reventless GWT');

async function discover() {
  const proc = spawn('reventless-gwt', ['discover', '--format=vscode']);
  for await (const line of readNDJSON(proc.stdout)) {
    if (line.event === 'item') {
      const item = controller.createTestItem(line.id, line.label, vscode.Uri.parse(line.uri));
      if (line.range) item.range = toRange(line.range);
      const parent = items.get(line.parent) ?? controller.items;
      parent.children.add(item);
      items.set(line.id, item);
    }
  }
}

controller.createRunProfile('Run', vscode.TestRunProfileKind.Run, async (request, token) => {
  const run = controller.createTestRun(request);
  const filters = (request.include ?? []).map(item => item.id);
  const proc = spawn('reventless-gwt', ['run', '--format=vscode', ...filters.flatMap(f => ['--filter', f])]);
  token.onCancellationRequested(() => proc.kill('SIGINT'));
  for await (const line of readNDJSON(proc.stdout)) {
    const item = items.get(line.id);
    switch (line.event) {
      case 'testStart': run.started(item); break;
      case 'testPass': run.passed(item, line.durationMs); break;
      case 'testFail':
        const msg = new vscode.TestMessage(line.messages[0].message);
        msg.expectedOutput = line.messages[0].expected;
        msg.actualOutput = line.messages[0].actual;
        msg.location = toLocation(line.messages[0].location);
        run.failed(item, msg, line.durationMs);
        break;
      case 'testSkip': run.skipped(item); break;
      case 'runEnd': run.end(); break;
    }
  }
});
```

About 80 lines of TypeScript. Published to the VS Code Marketplace as a separate, optional `reventless-vscode` extension. **Continuous Run** wraps `reventless-gwt run --watch --format=vscode`, repeating the cycle on file change. **Cancellation** translates to SIGINT — the CLI marks in-flight tests as `testSkip{reason:"cancelled"}`, emits `runEnd`, exits cleanly.

##### Why a custom format and not `--format=tap`

| Concern | TAP | `--format=vscode` |
|---|---|---|
| Discovery without execution | not supported | dedicated `discover` mode |
| Per-test lifecycle (`testStart`) | implicit | explicit event |
| Source ranges for tree population | not in spec | first-class `range` field |
| Multiple messages per failure | one YAML block | `messages: array` |
| Pre-rendered expected/actual for diff view | hidden in YAML, must be parsed | top-level fields ready for `TestMessage` |
| Cancellation semantics | none | explicit `testSkip` with reason |

A TAP-based extension is buildable but every gap requires parsing/inferring on the extension side. The VS Code-specific format eliminates the translation layer.

#### How the AI loop accesses outcomes

The AI loop uses the same CLI as developers, just with `--format=json`:

```bash
reventless-gwt run --format=json examples/online-shop-dcb/catalog/tests/Category/StateChangeSlice/AddCategory_GWT.res
```

Parse stdout, inspect `mismatch.kind`, generate a fix, repeat. No Jest stdout to parse. No log scraping. The structured Outcome plus the precomputed `hint.locus`/`hint.branch`/`hint.message` is enough to converge in 2–3 iterations on a typical slice.

For tightly-coupled in-process tooling (e.g. an agent running inside the same Node process via the Claude SDK), `import('./CategoryBehavior_GWT.res.mjs')` and call the GWT functions directly — `then*` already returns `Outcome.outcome`, no CLI needed.

#### What's in the package

##### Public modules (test files import these)

| Module | Purpose |
|---|---|
| `ReventlessGwt.Behavior_GWT` and friends | The DSLs themselves (`Make` functor over the relevant Spec). |
| `ReventlessGwt.Bind` | `describe` / `test` functions. Returns `unit`, pushes outcomes to the in-process `Collector`. The single touchpoint between a test file and the CLI runner. |
| `ReventlessGwt.Filter` | Predicate helpers (`only`, `skip`, `xtest`) so test files can mark scenarios at the source. |
| `ReventlessGwt.JestBind` | Optional. Same `describe`/`test` shape but binds to Jest's `test`/`describe` globals. Test files swap from `Bind` to `JestBind` to opt back into Jest. |
| `ReventlessGwt.AsyncTest` | Jest-binding helper kept for non-GWT tests (the wrapper around `testPromise` that fixes the concurrency race). |
| `ReventlessGwt.Outcome` | The algebra (`mismatch`, `outcome`, `format`, `toJson`). |

##### CLI binary

| Asset | Purpose |
|---|---|
| `bin/reventless-gwt.mjs` | Node entry point declared in `package.json` `bin`. ~30 lines — argv parsing and dispatch into the ReScript-compiled core. |

##### Internal modules (compiled into the binary, not exported)

| Module | Purpose |
|---|---|
| `Cli.res` | Argv parsing — subcommands (`run`, `discover`, `watch`), flags (`--format`, `--filter`, `--stream`, `--schema-version`), exit-code policy. |
| `Discovery.res` | File walker — finds `*_GWT.res.mjs` under `tests/`, respects `.gitignore`. |
| `Loader.res` | Dynamic-imports each test module via `await import(url)`. Order matters because tests register at import time. |
| `Collector.res` | Module-level array that `Bind.test` pushes outcomes into. Drained once per file by `Cli.res`. |
| `RenderRescript.res` | Sury-aware value renderer. Walks an `S.t<'a>` schema + a JSON value and produces ReScript syntax (`Added({name: "Electronics"})`). |
| `Diff.res` | Schema-aware structural diff. Given two values + their schema, produces `fieldDiff`. |
| `Hint.res` | Maps `Outcome.mismatch.kind` → `{locus, branch, message}`. The single source of truth for fix-locus inference. |
| `formatters/Human.res` | Terminal-coloured human formatter (~150 lines, biggest single piece). |
| `formatters/Json.res` | Structured JSON envelope (default) and NDJSON streaming variant. |
| `formatters/Tap.res` | TAP 14 line-by-line emitter with YAML diagnostic blocks. |
| `formatters/Junit.res` | JUnit XML emitter. |
| `formatters/VsCode.res` | NDJSON event stream tailored for VS Code Test API. |
| `Watch.res` | `chokidar`-based file watcher; on change, re-runs only the affected files. |
| `Cancellation.res` | SIGINT trap that flushes `runEnd`, marks in-flight tests as `skipped`, exits cleanly. |

##### Folder placement in the monorepo

```
reventless/
  reventless-gwt/                  ← new package, framework category
    bin/reventless-gwt.mjs
    src/
      Bind.res
      JestBind.res
      Filter.res
      AsyncTest.res
      Outcome.res
      Cli.res
      Discovery.res
      Loader.res
      Collector.res
      RenderRescript.res
      Diff.res
      Hint.res
      Watch.res
      Cancellation.res
      gwt/
        Behavior_GWT.res
        EventMapping_GWT.res
        Projection_GWT.res
        StateChangeSlice_GWT.res
        StateViewSlice_GWT.res
        AutomationSlice_GWT.res
        InboundTranslationSlice_GWT.res
        OutboundTranslationSlice_GWT.res
        Mapping_GWT.res
        Query_GWT.res
      formatters/
        Human.res
        Json.res
        Tap.res
        Junit.res
        VsCode.res
    tests/
      ...
    rescript.json
    package.json
    README.md
```

##### `package.json` shape

```json
{
  "name": "@reventlessdev/reventless-gwt",
  "version": "0.1.0",
  "description": "Reventless Given-When-Then DSLs and CLI runner",
  "bin": { "reventless-gwt": "./bin/reventless-gwt.mjs" },
  "main": "./src/Bind.res.mjs",
  "exports": {
    ".": "./src/Bind.res.mjs",
    "./jest": "./src/JestBind.res.mjs",
    "./outcome": "./src/Outcome.res.mjs"
  },
  "dependencies": {
    "@reventlessdev/reventless-spec": "*",
    "sury": "^11.0.0",
    "chokidar": "^4.0.0",
    "picocolors": "^1.0.0"
  },
  "peerDependencies": {
    "@glennsl/rescript-jest": "*"
  },
  "peerDependenciesMeta": {
    "@glennsl/rescript-jest": { "optional": true }
  },
  "engines": { "node": ">=22" },
  "publishConfig": { "registry": "https://npm.pkg.github.com" }
}
```

Jest is an optional peer dep — only consumed if the user opts into `JestBind` or `AsyncTest`.

##### Versioning relationship

| Change | Bump in `reventless-gwt` |
|---|---|
| `Outcome.outcome` algebra | major (every dependent test file recompiles) |
| Output schemas (JSON `schemaVersion`, TAP layout) | tracked separately via `schemaVersion` field, not the package version |
| New formatter | minor — additive |
| New `Outcome.mismatch` variant | minor (formatters need to handle it; default emits `Throw`-shaped fallback) |
| `Bind` API surface | major; every test file recompiles |
| New DSL module | minor — additive |

The `schemaVersion` field on JSON output decouples the *runner* version from the *output contract* version. LLM prompts and IDE extensions pin the contract, not the runner build.

#### Cost to build

| Component | Lines (approx) |
|---|---|
| Test discovery walker | ~30 |
| Test loader + collector | ~40 |
| Argv parsing + dispatcher | ~40 |
| `RenderRescript` (sury-aware) | ~120 |
| `Diff` (schema-aware) | ~80 |
| `Hint` (mismatch → locus) | ~40 |
| Human formatter | ~150 |
| JSON formatter | ~80 |
| TAP formatter | ~70 |
| JUnit formatter | ~50 |
| VS Code formatter + discover mode | ~110 |
| Watch + cancellation | ~50 |
| `Bind` / `JestBind` / `AsyncTest` | ~60 |
| **Total runner** | **~920** ReScript |
| `reventless-vscode` extension | ~80 TypeScript (separate package) |

Plus the GWT DSL modules themselves (~150 lines each × ~10 = ~1500 lines, mostly translation of existing `BehaviorTest`/`ProjectionTest` code with the Outcome algebra wired through). Grand total well under 3000 lines of ReScript for the whole testing toolchain — smaller than a typical Jest configuration with custom reporters and TAP/JUnit transformers.

#### What we lose by dropping Jest

Honest accounting:

- **Snapshot testing** — not used by any GWT (snapshots and example-based GWT are different patterns).
- **Mocks/spies** — not needed for pure GWT (slices are pure).
- **Existing IDE integrations** — replaced by `reventless-vscode`.
- **Familiarity** — every team member already knows Jest. The CLI is one new tool to learn, but GWT files barely use Jest's surface anyway (`describe`/`test`).

Net assessment: keep Jest available for **non-GWT** tests (component integration tests, infrastructure tests, the in-memory bus tests) where it earns its keep. Move GWT tests to the Reventless-owned runner.

---

## 4. The DSL set

All DSLs follow the same shape: `Make` functor over the relevant Spec, identical verb vocabulary, return `Outcome.outcome`, runner-agnostic.

DCB DSLs assume the test package can introspect schemas via `Reventless.DcbTag` and `Reventless.DcbDecode` (both already in `reventless-spec`).

### 4.1 Renaming the existing DSLs

The current names (`BehaviorTest`, `EventMappingTest`, `ProjectionTest`) read like "tests *of* Behavior/EventMapping/Projection", but they are GWT DSLs. Mixing `*Test` and `*_GWT` suffixes inside one package is the kind of inconsistency that makes a framework feel foreign. Rename:

| Old name | New name |
|---|---|
| `BehaviorTest` | `Behavior_GWT` |
| `EventMappingTest` | `EventMapping_GWT` |
| `ProjectionTest` | `Projection_GWT` |
| `AsyncTest` | (kept as `AsyncTest`) — not a GWT, it's a Jest-binding helper |

Deprecation aliases in `Deprecated.res` keep the old names compiling for one release cycle.

### 4.2 `StateChangeSlice_GWT`

```rescript
include ReventlessGwt.StateChangeSlice_GWT.Make(AddCategory)
include ReventlessGwt.Bind

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

Implementation: `Make(Spec: StateChangeSlice.Spec)` runs `evolve` over the given consumed events to build state, then calls `decide(state, command)`. Identical mental model to `Behavior_GWT`, but typed against `Spec.consumedEvent` and `Spec.event` (which need not be the same type — the GWT layer must respect this).

#### Auto-deriving `thenAppendsConditionedOn`

The append condition that a `StateChangeSlice` issues at runtime is a pure function of (1) the command schema's tagged fields and (2) the slice's `consumedEvent` schema's variant constructors. Both are statically known. `Reventless.DcbTag.buildQueryFromCommand` and `Reventless.DcbTag.extractVariantNames` already compute exactly this query inside the runtime. The GWT DSL can call the same helpers:

```rescript
let computeExpectedAppendCondition = (cmd: Spec.command): DcbTag.appendCondition => {
  let eventTypes = DcbTag.extractVariantNames(Spec.consumedEventSchema)
  let query = DcbTag.buildQueryFromCommand(~eventTypes, ~schema=Spec.commandSchema, ~value=cmd)
  {query: query}
}
```

So three modes are useful:

| Mode | When to use | What it does |
|---|---|---|
| **Default — implicit** | Always on. | Every `whenCmd` *internally* checks that the auto-derived append condition matches what the slice's runtime would build. A divergence (e.g. dev forgot `@s.matches(DcbTag.string)`) fails with `AppendConditionMismatch`. |
| **Explicit override** | When the dev wants the spec to **document** the optimistic-concurrency contract. | `->thenAppendsConditionedOn([...])` accepts a literal expectation; both sides compared for equality. Protects against silent regressions. |
| **Strict-only** | When locking the contract without computing it. | `->thenAppendsConditionedOnExactly([...])` skips auto-derivation, asserts the literal only. |

**Recommendation**: ship the implicit assertion first; expose `thenAppendsConditionedOn` as documentation-only override. The auto-derivation is sound *because* the framework already uses the same helper at runtime — there is no second source of truth that can drift.

Same pattern generalises to `consumedEvent` set (auto-derived from `givenEvents` union variants) and partition tag (auto-derived via `DcbTag.derivePartitionTag`). All three are **invisible by default, documentable on request**.

### 4.3 `StateViewSlice_GWT`

Mirrors `Projection_GWT` but driven by the slice's `consumedEvent`:

```rescript
include ReventlessGwt.StateViewSlice_GWT.Make(CategoriesView)
include ReventlessGwt.Bind

givenEvents([CategoryAdded({categoryId: "c1", name: "X"})])
->whenEvent(CategoryRenamed({categoryId: "c1", name: "Y"}))
->thenState("c1", {categoryId: "c1", name: "Y", archived: false})
```

Internally reuses `Projection.handleActions` against an in-memory dict store, exactly like `Projection_GWT`. The only delta is no `Projection.Mapping` indirection — the slice's `project` function consumes the event directly.

### 4.4 `AutomationSlice_GWT`

Three GWT operations exercised independently and one composed scenario:

```rescript
include ReventlessGwt.AutomationSlice_GWT.Make(ShipOrder)
include ReventlessGwt.Bind

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

### 4.5 `InboundTranslationSlice_GWT`

```rescript
include ReventlessGwt.InboundTranslationSlice_GWT.Make(PaymentWebhook)
include ReventlessGwt.Bind

whenInput({paymentId: "p1", orderId: "o1", status: "completed"})
->thenCommands([("o1", ConfirmPayment({orderId: "o1", paymentId: "p1"}))])

whenInput({paymentId: "p1", orderId: "o1", status: "garbage"})
->thenTranslateError("Unknown payment status: garbage")
```

No `given` clause — translation has no prior state.

### 4.6 `OutboundTranslationSlice_GWT`

The translate function is async and may produce a follow-up command. The DSL needs to mock the external service:

```rescript
include ReventlessGwt.OutboundTranslationSlice_GWT.Make(SendTrackingEmail)
include ReventlessGwt.Bind

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

### 4.7 `Mapping_GWT` — cross-pattern automation

Generalises `EventMapping_GWT` so source and target can each be either an Aggregate `Behavior` or a `StateChangeSlice`. This is the GWT equivalent of the four producer/consumer combinations across the Aggregate and DCB patterns. The functor accepts `module(Source.T)` where `Source.T` abstracts Behavior + StateChangeSlice via a small Spec record (`name`, `decide`, `evolve`, `initialState`, `event`, `consumedEvent`).

### 4.8 `Query_GWT` — read model query patterns

ReadModels and StateViewSlices have a side that `Projection_GWT` does not address: **what queries must the projected state support?** Indexes, sub-ID composite keys, GraphQL resolvers, and AppSync auth groups all exist to answer specific query patterns. None of these are derivable from the projection's `project` function.

```rescript
include ReventlessGwt.Query_GWT.Make(CategoriesReadModel)
include ReventlessGwt.Bind

describe("CategoriesReadModel queries", () => {
  test("by primary id returns the row", () =>
    givenStore([
      ("c1", {categoryId: "c1", name: "Electronics", archived: false}),
      ("c2", {categoryId: "c2", name: "Books", archived: true}),
    ])
    ->whenQueryById("c1")
    ->thenRow(Some({categoryId: "c1", name: "Electronics", archived: false})))

  test("by name (GSI) returns matching rows", () =>
    givenStore([...])
    ->whenQuery({by: "name", value: "Electronics"})
    ->thenRows([...]))

  test("paginated query respects limit", () =>
    givenStore([...20 rows...])
    ->whenQuery({by: "categoryGroup", value: "x", limit: 5})
    ->thenRowCount(5))
})
```

For composite-key tables and resolvers:

```rescript
test("primary + sub-id uniquely identifies row", () =>
  givenStore([(("u1", "v1"), ...), (("u1", "v2"), ...)])
  ->whenQueryByCompositeId({id: "u1", subId: "v2"})
  ->thenRow(Some(...)))

test("Order resolves Customer via customerId", () =>
  givenStore_for(CustomerReadModel, [...])
  ->andStore_for(OrderReadModel, [...])
  ->whenResolve({from: "Order", id: "ord-1", field: "customer"})
  ->thenResolved({customerId: "c1", name: "Acme"}))
```

Each scenario type pins down a piece of `ReadModel.config`:

| Scenario | Constrains |
|---|---|
| `whenQueryById` | primary key — automatic from `@id` annotation |
| `whenQuery({by: "name"})` without `index` | `name` must be primary key OR an index on `name` is needed |
| `whenQuery({by: X, index: "Y"})` | requires a GSI named `"Y"` on field `X` |
| `whenQuery({..., filter: ...})` | filter expression — no infrastructure needed |
| `whenQueryByCompositeId` | requires `subIdConfig` with the right `subIdField` |
| `whenResolve` | requires `idResolvers` entry pointing at the target table/field |
| `whenResolveMany` | requires `idsResolvers` entry |
| `withAuthGroup("admins")` | requires `authorization` on the index |

The AI loop reads `Query_GWT` scenarios, computes the required `config`, and emits the right `@index`, `@indexSubId`, `@resolves`, `@resolvesMany`, `@compositeId` annotations on the `state` record. The PPX picks them up.

`Query_GWT` is independent of `Projection_GWT` — they test different concerns of the same read model. A complete read model spec has both.

### 4.9 Final harmonised module list

After consolidation, `reventless-gwt` ships:

```
reventless/reventless-gwt/src/
├─ Bind.res                      # Outcome → CLI runner
├─ JestBind.res                  # Outcome → Jest (optional)
├─ Filter.res                    # only/skip/xtest
├─ AsyncTest.res                 # Jest binding helper for non-GWT tests
├─ Outcome.res                   # the algebra
├─ ... (CLI internals)
└─ gwt/
   ├─ Behavior_GWT.res           # Aggregate command slice
   ├─ EventMapping_GWT.res       # Aggregate→Aggregate automation
   ├─ Projection_GWT.res         # ReadModel projection
   ├─ StateChangeSlice_GWT.res   # DCB command slice
   ├─ StateViewSlice_GWT.res     # DCB view slice
   ├─ AutomationSlice_GWT.res    # DCB automation
   ├─ InboundTranslationSlice_GWT.res
   ├─ OutboundTranslationSlice_GWT.res
   ├─ Mapping_GWT.res            # cross-pattern automation
   └─ Query_GWT.res              # read model query patterns
```

Same shape every file: `Make` functor, identical verb vocabulary, returns `Outcome.outcome`, runner bound via `Bind` (or `JestBind`).

---

## 5. AI-assisted generation

Given a corpus of:

- Reventless component **specs** (the `*.res` files under `Aggregate/`, `StateChangeSlice/`, etc.)
- A set of **GWT scenarios** in either ReScript or a Markdown/JSON DSL
- The framework's **PPX conventions** and **placement rules** (already encoded in `.claude/rules/` and CLAUDE.md)

…how completely can the implementation + tests be generated?

### 5.1 What is mechanically derivable

Direct projections from the GWT corpus and existing schemas:

| Artifact | Source of truth | Derivability |
|---|---|---|
| Command/event/error type variants | enumeration of `whenCmd` / `thenEvent` constructors | **trivial** |
| Sury `@schema` annotations | from the type definitions | **trivial** |
| DCB tag annotations | enumeration of `*Id` field patterns + plurality per CLAUDE.md PPX rules | **mechanical** (PPX does the work) |
| `consumedEvent` set (DCB slices) | the union of constructors used in `givenEvents` | **trivial** |
| `state` shape for `evolve` | smallest record satisfying all `decide` branches | **derivable with a search** (cost-function bias) |
| `evolve` body | one branch per consumed event from `givenEvents → state` examples | **derivable** but ambiguous when corpus incomplete |
| `decide` body | one branch per `whenCmd` from `state → command → events` examples | **derivable but lossy** — see 5.3 |
| `Projection.action` choices in `project` | derivable from `givenEvents → store, whenEvent → store` deltas | **mechanical** for `Set/Update/Delete`; ambiguous `UpdateWithDefault` vs `Set` |
| StateChangeSlice append-condition | union of tagged fields × consumed event types | **mechanical** once the slice body exists |
| Plugin wiring (`Plugin.res`) | already generated by `generate-plugin` from folder layout | **already automated** |

### 5.2 What needs LLM judgment

Not mechanical — needs design-level inference:

- **Whether a slice is Aggregate, DCB StateChangeSlice, or both** — see [`aggregate-vs-dcb-decision-guide.md`](../guides/aggregate-vs-dcb-decision-guide.md). LLM applies the heuristic given the GWT corpus.
- **Naming and folder placement** — covered by `.claude/rules/app-developer.md`.
- **`evolve` minimality** — many `state` shapes satisfy the same corpus. LLM should bias toward smallest sum of fields.
- **Idempotency choices** — `whenCmd(X)->thenNoEvent` on an already-effected state: `Ok([])` (idempotent, project convention) or `Error(SomeError)`?
- **Error taxonomy** — `CategoryAlreadyExists` vs `DuplicateAdd` is a design choice not pinned by GWT examples.

### 5.3 What CANNOT be derived

These must be in the GWT corpus or generation will fail / hallucinate:

- **Cross-entity invariants** that aren't exercised by any example — there's no way to know "you cannot place an order for an archived product" without a scenario that demonstrates it.
- **Side-effect contracts** beyond what's recorded in events.
- **Read model query patterns** — these are not implied by Given/When/Then on the projection. They need their own `Query_GWT` corpus (§4.8).

### 5.4 Generation pipeline

#### Input artefacts

- **Domain spec packages** (`*Spec/`) — already-existing or to-be-generated `.res` files declaring `@@reventless.spec` types.
- **GWT corpus** — one file per scenario:
  - **ReScript form** (`tests/<Slice>/<Name>_GWT.res`) — canonical, type-checked.
  - **Markdown/JSON form** (`scenarios/<slice>.gwt.md`) — for human-authored or Event Modeling tool input. A pre-step compiles to ReScript.
- **Conventions corpus** — `.claude/rules/*.md` and CLAUDE.md.

#### Stage A — mechanical skeleton derivation

**No LLM.** A rule-based generator (extension of `generate-plugin`) reads the GWT corpus and emits:

- Folder layout — derived from slice name + slice kind in each GWT file.
- Empty spec/behavior `.res` files with `@@reventless.spec` / `@@reventless.behavior` headers.
- Type declarations:
  - `command` — one constructor per distinct `whenCmd(X(...))` payload shape.
  - `event` — one constructor per distinct `thenEvent(Y(...))` payload shape.
  - `error` — one constructor per distinct `thenError(Z)`.
- PPX annotations — `@s.matches(DcbTag.string)` on `*Id: string` fields per existing rules.

Output: project that **compiles** but every `evolve`/`decide` is the no-op stub. Every GWT test fails — TDD red phase.

Stage A is reversible and idempotent — re-running on a new GWT only adds new constructors, never overwrites a developer's `evolve`/`decide`.

#### Stage B — LLM synthesises `evolve` + `decide`

Per slice, LLM receives:

- The slice's spec file.
- The GWT corpus for that slice.
- Relevant CLAUDE.md / rules excerpts.

Emits a candidate `evolve` and `decide` body, runs the slice's GWT through `reventless-gwt run --format=json`, feeds the Outcome JSON back. If every `then*` is `Ok`, accept. Otherwise the structured mismatches name exactly which branch is wrong (§3.2 hint table) and the LLM iterates.

Termination conditions: all scenarios pass → done. N iterations without progress → escalate (corpus likely incomplete or contradictory).

Per-slice and embarrassingly parallel.

#### Stage C — LLM synthesises `project` for view slices

Same loop as Stage B but for `ReadModel`/`StateViewSlice` projections, using `Projection_GWT` / `StateViewSlice_GWT` corpus. LLM emits the `project` function.

Edge case: ambiguity between `Set` and `UpdateWithDefault` when the corpus only contains positive cases. Prefer `Set` (overwriting semantics, matches event-sourcing replay) unless a scenario explicitly tests partial-update behaviour.

#### Stage D — LLM synthesises read model query infrastructure

Uses `Query_GWT` corpus (§4.8). LLM derives `ReadModel.config` (indexes, idResolvers, idsResolvers, subIdConfig) by working backward from query examples. "Bounded creativity" means: the LLM may propose an index, but it must justify it from at least one Query_GWT scenario.

#### Stage E — mechanical acceptance gate

**No LLM.** Run:

1. `generate-plugin src/` — wires every component into `Plugin.res`.
2. `pnpm run build` — ReScript compile check.
3. `pnpm exec reventless-gwt run` — every GWT runs, must all be `Ok`.
4. Optionally `pnpm test` — Jest still runs the non-GWT tests (E2E, infrastructure).

If all pass, accept. If any fail, re-invoke the LLM at the relevant stage (B for behaviour failures, C for projection failures, D for query failures). The mismatch JSON tells the orchestrator which stage to retry.

#### Where each stage gets its truth

| Stage | Source of truth | What's at stake if missing |
|---|---|---|
| A | GWT corpus + `.claude/rules/` | Wrong folder, missing PPX → caught at compile time |
| B | GWT corpus + Outcome feedback | Wrong domain logic → caught by GWT failures |
| C | `Projection_GWT` / `StateViewSlice_GWT` corpus | Wrong projection actions → caught by GWT failures |
| D | `Query_GWT` corpus | Wrong indexes → ReadModel won't satisfy required queries |
| E | All of the above | Build fails → human investigation |

The Outcome algebra (§3.2) is the load-bearing invariant for stages B–D. Without it, every iteration parses test runner stdout, which dilutes the signal and makes long iteration loops infeasible.

### 5.5 What unlocks the highest leverage

In priority order:

1. **Build the missing DCB DSLs (§4.2–4.7).** Without them, the GWT corpus can only describe Aggregate slices — half the framework is invisible to the AI loop.
2. **Adopt the `Outcome` algebra (§3.2).** Without structured failures, AI iteration depends on parsing test output.
3. **Add `Query_GWT` (§4.8).** Closes the index/resolver design gap.
4. **Encode the GWT shapes as a JSON schema.** Lets AI tools accept declarative inputs (or Event Modeler exports) and emit ReScript GWT files. Pairs with [`event-modeling-json-reventless-conversion.md`](./event-modeling-json-reventless-conversion.md).
5. **PPX `@@reventless.gwt`** to remove the `include ...GWT.Make(...)` boilerplate and lock the convention down.

With all five in place, "I provide the spec and the GWT" → "framework runs, passes" becomes a closed AI iteration loop with the Outcome algebra serving as the fitness function.

---

## 6. Implementation plan

A staged, additive migration. Each stage is one PR that keeps every test green via deprecation aliases.

### 6.1 Phased migration

1. **Stage 1 — Consolidate.** Create `reventless-gwt` package. Move `BehaviorTest`, `EventMappingTest`, `ProjectionTest`, `AsyncTest` from `reventless-core/tests/` into it. Delete the duplicates in `reventless-in-memory/src/test/` (see §6.1.1). Codemod example tests to `ReventlessGwt.*` imports. Keep current `Jest.assertion` return type to minimize churn.
2. **Stage 2 — Outcome algebra.** Refactor combinators to return `Outcome.outcome`. Add `JestBind` adapter so existing test files compile unchanged (the adapter wraps the outcome at the `test(...)` boundary, not in `then*` calls).
3. **Stage 3 — DCB DSLs.** Add `StateChangeSlice_GWT`, `StateViewSlice_GWT`, `AutomationSlice_GWT`, `InboundTranslationSlice_GWT`, `OutboundTranslationSlice_GWT`. Each mirrors the existing DSL shape so users learn one vocabulary.
4. **Stage 4 — `thenAppendsConditionedOn`.** Add the implicit + explicit append-condition assertion to `StateChangeSlice_GWT` (§4.2).
5. **Stage 5 — Cross-pattern `Mapping_GWT`.** Generalise `EventMapping_GWT` so source and target can be Behavior or StateChangeSlice (§4.7).
6. **Stage 6 — `Query_GWT`.** Add the read-model query DSL (§4.8).
7. **Stage 7 — CLI runner.** Build `reventless-gwt` CLI with `--format=human|json|tap|junit|vscode`. At this point Jest is one of multiple runners.
8. **Stage 8 — `reventless-vscode` extension.** Ship the VS Code extension as a separate marketplace package.
9. **Stage 9 — `@@reventless.gwt` PPX.** File-level annotation that auto-injects `include ...GWT.Make(...)` based on folder convention (mirrors `@@reventless.spec`/`@@reventless.behavior`). Eliminates the boilerplate first lines of every test file.
10. **Stage 10 — Documentation.** A new `docs/guides/given-when-then.md` with one fully-worked example per slice type. Cross-link from `docs/guides/component-testing-guide.md`.

The runner-agnostic shape is established by Stage 2; everything from Stage 3 onward is additive on top of the same Outcome algebra.

#### 6.1.1 Stage 1 detail: removing the `reventless-in-memory` re-exports

The current re-exports exist for two specific reasons. Both go away once the DSLs live in `reventless-gwt`:

| Reason re-export exists today | Why it can be removed |
|---|---|
| Example packages would otherwise need a direct `reventless-core` dev dep just to access the DSLs (and `reventless-core` carries the framework runtime). | After Stage 1, examples depend on `reventless-gwt`, which has only `reventless-spec` + optional Jest. No framework runtime is pulled in. |
| `@send external toBe` bindings defined in another package's namespace fail with "The value toBe can't be found" when downstream packages don't depend on the originating package (see `AsyncTest.res` comment). | All `@send` externals move into `reventless-gwt/src/AsyncTest.res`. Every downstream depends transitively on `reventless-gwt`, so externals always resolve. |

**Concrete actions:**

1. `git mv reventless/reventless-core/tests/{BehaviorTest,EventMappingTest,ProjectionTest,AsyncTest}.res reventless/reventless-gwt/src/`
2. Rename to `Behavior_GWT.res`, `EventMapping_GWT.res`, `Projection_GWT.res`, `AsyncTest.res`.
3. `rm reventless/reventless-in-memory/src/test/{BehaviorTest,ProjectionTest,AsyncTest}.res` and their `.res.mjs` siblings.
4. Update `reventless-in-memory/rescript.json` to remove `src/test`, or reduce to `Mocks/` and `TestRunner.res` only.
5. Add `@reventlessdev/reventless-gwt` as a devDep of `reventless-in-memory` (only because some `TestRunner` helpers use `AsyncTest`).
6. Codemod every example test: `ReventlessInMemory.BehaviorTest` → `ReventlessGwt.Behavior_GWT`, `ReventlessInMemory.ProjectionTest` → `ReventlessGwt.Projection_GWT`, `ReventlessInMemory.AsyncTest` → `ReventlessGwt.AsyncTest`.
7. Add a thin `ReventlessInMemory.BehaviorTest = ReventlessGwt.Behavior_GWT` deprecation alias in `reventless-in-memory/src/test/Deprecated.res` for one release cycle.
8. Update `MEMORY.md` notes that reference the old paths.

The only thing the in-memory package retains in `src/test/`:

- `TestRunner.res` — Pulumi mock activation helper. Specific to in-memory infrastructure tests, not a GWT.
- `Mocks/` — in-memory channel mocks for E2E tests. Specific to in-memory wiring.

### 6.2 Test file migration

| Location | Count (approx) | Migration shape |
|---|---|---|
| `examples/online-shop-aggregates/*/tests/Aggregate/*BehaviorTest.res` | ~4 | rename + import path swap (codemod) |
| `examples/online-shop-aggregates/*/tests/ReadModel/*ProjectionTest.res` | ~4 | rename + import path swap (codemod) |
| `examples/online-shop-aggregates/*/tests/E2E/*E2ETest.res` | ~4 | unchanged (uses in-memory bus, not GWT) |
| `examples/online-shop-dcb/*/tests/*/StateChangeSlice/*DecisionTest.res` | ~4 | rewrite to `_GWT` form (semi-automatic) |
| `examples/online-shop-dcb/*/tests/*/StateViewSlice/*ViewTest.res` | ~4 | rewrite to `_GWT` form (semi-automatic) |
| `examples/online-shop-dcb/*/tests/E2E/*E2ETest.res` | ~2 | unchanged (uses in-memory bus, not GWT) |
| `reventless/reventless-core/tests/**` | many | unchanged or in-place rename |
| `reventless/reventless-in-memory/tests/**` | many | unchanged |

#### Codemod for renames (Aggregate Behavior + ReadModel Projection)

Mechanical:

```
- include ReventlessInMemory.BehaviorTest.Make(Category, CategoryBehavior)
+ include ReventlessGwt.Behavior_GWT.Make(Category, CategoryBehavior)
+ include ReventlessGwt.Bind
```

Plus optional file rename: `CategoryBehaviorTest.res` → `CategoryBehavior_GWT.res`. Combinator names stay the same — every `givenEvents/whenCmd/thenEvent` call works as-is. With deprecation aliases in place, this can land in any order. ~1 hour to write the codemod, then auto-applies.

If the harmonisation work (§2.6 item 3) drops `plainPartial` in favour of a synchronous chain, the projection codemod also rewrites `whenEvent(...)->thenState(...)` from `Jest.Expect.plainPartial<...>` to a regular value chain. Slightly bigger but still mechanical (LHS/RHS shapes are deterministic).

#### Semi-automatic LLM rewrite for DCB hand-rolled tests

The current `*DecisionTest.res`-style files use raw `expect(...)->toEqual(...)` against `decide`/`evolve` directly. The migration to `StateChangeSlice_GWT` form is *structural*, not a string substitution:

1. **Manual** — each ~50–100 line file is rewritten by hand. Predictable for ~8 files.
2. **LLM-assisted** — give the LLM the old test + the `StateChangeSlice_GWT` API surface, emit the new GWT form. Verify by running the new test against unchanged production code.

For the monorepo's ~8 DCB hand-rolled files, manual is realistic for a single afternoon. The LLM-assisted route is the better pattern for downstream apps that may have hundreds.

#### E2E tests — unchanged

E2E tests dispatch real commands through an in-memory bus and count events. They are *integration* tests, not GWTs. Stay as-is. Long term they could be expressed as `Mapping_GWT` scenarios (§4.7) but that's a separate effort.

### 6.3 Deprecation strategy

Two `Deprecated.res` files keep every existing test compiling for one release cycle:

```rescript
// reventless-gwt/src/Deprecated.res
@deprecated("Use Behavior_GWT instead")
module BehaviorTest = Behavior_GWT
@deprecated("Use Projection_GWT instead")
module ProjectionTest = Projection_GWT
@deprecated("Use EventMapping_GWT instead")
module EventMappingTest = EventMapping_GWT
```

```rescript
// reventless-in-memory/src/test/Deprecated.res
@deprecated("Use ReventlessGwt.Behavior_GWT instead")
module BehaviorTest = ReventlessGwt.Behavior_GWT
@deprecated("Use ReventlessGwt.Projection_GWT instead")
module ProjectionTest = ReventlessGwt.Projection_GWT
@deprecated("Use ReventlessGwt.AsyncTest instead")
module AsyncTest = ReventlessGwt.AsyncTest
```

Each ReScript build emits deprecation warnings. After one release cycle and all internal tests migrated, delete the deprecated modules.

For DCB slices that today have **no** GWT (raw `expect`), migration is net-new authoring rather than refactoring. The LLM-assisted route in 6.2 seeds the GWT corpus from existing Decision tests so coverage is preserved on day one.

---

## 7. Summary of recommendations

- **One package: `reventless-gwt`** (§3.1). Houses every GWT DSL, the `Outcome` algebra, the CLI runner, the optional `JestBind` adapter, and the `AsyncTest` Jest-binding helper. `reventless-spec` stays runtime-free.
- **Refactor `then*` to return `Outcome.outcome`** (§3.2). Structured outcomes drive every consumer (Jest, AI loop, CLI runner, IDE) and the precomputed `hint` field tells consumers exactly which function to fix.
- **Build the `reventless-gwt` CLI runner** (§3.3) with `--format=human|json|tap|junit|vscode`. Replaces Jest for GWT files, produces ReScript-aware diffs, gives the AI loop and the IDE the same structured data without parsing test output.
- **Add five missing DSLs** (§4.2–4.6): `StateChangeSlice_GWT`, `StateViewSlice_GWT`, `AutomationSlice_GWT`, `InboundTranslationSlice_GWT`, `OutboundTranslationSlice_GWT`.
- **Generalise `EventMapping_GWT` to `Mapping_GWT`** (§4.7) so source and target can each be Behavior or StateChangeSlice — closes the cross-pattern gap.
- **Add `thenAppendsConditionedOn` with auto-derivation** (§4.2.1) so the DCB optimistic-concurrency contract is checked implicitly and documentable explicitly.
- **Add `Query_GWT`** (§4.8) so read model index/resolver/subId design is specifiable, closing the only major gap for full AI generation of read models.
- **Rename and harmonise the existing DSLs** (§4.1, §2.6): `BehaviorTest`→`Behavior_GWT`, `ProjectionTest`→`Projection_GWT`, `EventMappingTest`→`EventMapping_GWT`. Standardise vocabulary, drop module-level `errors` ref, finish missing error combinators, delete duplicated `reventless-in-memory/src/test/*` modules.
- **Migration is fully additive** (§6): codemods for the existing rename, semi-automatic LLM rewrite for the few DCB hand-rolled tests, deprecation aliases keep every PR green.
- **AI generation is feasible to a high ceiling** (§5) but only if the GWT corpus covers every cross-entity invariant. The two non-derivable areas — invariants without examples, read-model query patterns — must be made explicit as `_GWT` or `Query_GWT` scenarios. Otherwise an LLM will under-constrain `decide` and over-fit on the supplied examples.
