# Plan: automation and translation tests take the slice as written, and the sidecars read them

**Status:** Done 2026-10-09. See [As built](#as-built) for where it differs.<br/>
**Repos:** `reventless-core` only. `packages/reventless-ppx` (`SidecarEmit.ml`, `GwtInference.ml`,
`Util.ml`, `src/test_sidecar/`, `test/run.sh`), `reventless/gwt`, `reventless/spec`
(`CheckLifecycleModel.res`), the example shops' tests, and the guides.<br/>
**Analysis:** [testing-translation-slices.md](../../analysis/testing-translation-slices.md).<br/>
**Companion:** reventless-tools reads the new step kinds, `componentKind`, the ordered `steps`
and the `.wiring.json` sidecar. Its readers already skip unknown step kinds, so this plan can
ship first.

## Goal

An automation slice's or a translation slice's test is written against the slice as it is
written, with no adapter module. What it asserts reaches the `.gwt.json` sidecar. And the
`.model.json` sidecar, plus a new sidecar for an automation's body, says what starts a slice
and where its commands go.

## Why

Tools read slices and scenarios from the sidecars, not from the source. For these three kinds
the sidecars lose most of what the source says, in three ways.

### Gap 1: the scenario sidecar cannot read these tests

`SidecarEmit` harvests only `test(...)`, and only these verbs: `givenEvent(s)`;
`whenCmd`/`whenCommand`, `whenInput`, `whenEvent(s)`; `thenEvent(s)`, `thenError`, the
`thenState` family, `thenNoState`, `thenCommand`, `thenSideEffect`, `thenNoEvent` and
`thenRefused` ([SidecarEmit.ml](../../../packages/reventless-ppx/src/ppx/SidecarEmit.ml),
`step_names`). Every other verb is skipped in silence.

The verbs it skips are those the automation, translation and flow DSLs are written in. For
automation and translation DSLs: `whenCollect`, `thenTodos`, `whenResolve`, `thenResolved`,
`givenTodo`, `whenProcess`, `whenSweep`, `thenCommands`, `thenScenarioTodos`, `andThenEvents`,
`thenNoCommand`, `thenTranslateError`, `whenTranslateMocked`, `whenTranslateRetrying`,
`thenTodoStatus` and `thenRetryRecorded`. For flows: `whenReacts`, `thenIssuesCommand(s)`,
`thenIssuesNoCommand`, `thenOutbound(Nothing)`, `whenPublishedThrough`, `thenPublicEvent(s)`,
`whenExtensionReacts` and `thenViewState(s)`.

Three more losses:
- **`testSync` is not harvested.** VerifyCustomerEmail has 8 tests and its sidecar 6.
- **A record literal becomes `opaque`.** `whenInput({sku: …})` keeps its source text and no
  values.
- **One verb per group.** In a real build a chain with two `whenCommand`s records the last one
  written. The hybrid shop's ordering flow records `ShipOrder` as its *when*, not
  `PlaceOrder`.

Measured over the three example shops: every automation (21), inbound (11) and outbound (10)
scenario records no *when*. Most record no *then*. `CheckLifecycleModel --json` lists them as
`opaque`, and tools show a slice with 21 scenarios as untested.

### Gap 2: the DSLs expect a shape the slices do not have

| DSL | Expects | The slice as written |
|---|---|---|
| `Automation_GWT.Make(S)` | one module with `consumedEvent`, `collect(e)`, `resolve`, `process` | `Spec` (no consumed event) + `X_Automation` with `process`, `onExhausted` and `mappings: array<module(Mapping)>`; each mapping has its own `sourceEvent`, `collect(e, ~sourceId, context)`, `resolve` |
| `InboundTranslation_GWT.Make(S)` | `translate` on the spec | `translate` in `X_Translation` |
| `OutboundTranslation_GWT.Make(S)` | `collect` on the spec; `translate` never taken | `collect`, `translate(~capabilities)` and `onExhausted` in `X_Translation` |
| `Flow_GWT.AutomationStep(S)`, `OutboundStep(S)` | the same flat shapes | as above |

So every test begins with an adapter, which the PPX takes as "the first top-level module"
([GwtInference.ml](../../../packages/reventless-ppx/src/ppx/GwtInference.ml)):

```rescript
// examples/online-shop-hybrid/ordering/tests/Order/Automation/AutoShipOrder_GWT.res
module AutoShipOrderSlice = {
  include AutoShipOrder
  type consumedEvent = AutoShipOrder_Automation.FromOrderingDcb.sourceEvent
  let consumedEventSchema = AutoShipOrder_Automation.FromOrderingDcb.sourceEventSchema
  let collect = e => AutoShipOrder_Automation.FromOrderingDcb.collect(e, ~sourceId="", testContext)
  let resolve = AutoShipOrder_Automation.FromOrderingDcb.resolve
  let process = AutoShipOrder_Automation.process
}
@@reventless.gwt
```

An adapter tests one mapping at a time and hard-codes `~sourceId=""`. It hides `onExhausted`.
A generator would have to write it and keep it in step. The ordering flow repeats both
automation adapters.

### Gap 3: the model sidecar leaves out the wiring

`.model.json` is written only for a `@@reventless.spec` file. Its `config` takes three keys
(`targetName`, `maxRetries`, `heartbeatInterval`), and only when the binding is an unannotated
`let` bound to a bare literal (`config_entries`, `literal_value`). So:

- `targetName = Some("Customer")` (GeocodeCustomerAddress) is dropped, and so is any
  annotated `let targetName: string = …`;
- `sourceNames`, `externalSystem` (`ImportProduct` has `Some("SupplierFeed")`),
  `capabilityNeeds` and `traits` are never captured;
- a string literal is re-quoted without escaping;
- **an automation's source events are in no sidecar at all.** Since the consumed event left
  the automation spec, they live in `X_Automation.res` (`Mapping.Make(Source, Target, Impl)`,
  `let mappings`). Implementation files get no sidecar, and are excluded from `.types.json`.

---

## Phases

Phases 1 to 4 change the PPX and the GWT package and ship in **one PPX release**. The new
inference names functors the GWT package must already have. Phase 5 migrates the examples
once that release is published.

### Phase 1: the DSLs take the slice as written (gap 2)

**1a. Automation.** In `Automation_GWT`:

```rescript
module FromSlice: (
  Spec: Reventless.AutomationSlice.Spec,
  Automation: Reventless.AutomationSlice.Automation with module Spec := Spec,
) => { … }
```

- `givenTodo(id, item) → whenProcess → thenCommand(id, cmd) | thenNoCommand`
- `whenExhausted(id, item, ~lastError) → thenCommand | thenNoCommand`
- `givenEvents([Mapping.event(e), …]) → whenSweep → thenCommands | thenScenarioTodos`.
  The sweep dispatches through `Automation.mappings` keyed by `sourceName`, as
  `AutomationSlice_Callback.phase1` does. It reuses that code rather than copying it; the
  decode-and-route part moves to a pure helper both call.
- `module Mapping: (M: Automation.Mapping) => { … }` gives the typed per-source verbs. They
  are needed because `sourceEvent` is existential inside the array:
  - `givenEvent(e) → whenCollect(~sourceId=?) → thenTodos(items)`;
  - `whenResolve → thenResolved(id)`;
  - `event(e)`, which wraps a typed event for `givenEvents` above.
- The `context` is a fixed test context, overridable with `~context`.

**1b. Inbound.** `InboundTranslation_GWT.FromSlice(Spec, Translation)` keeps today's verbs and
takes `translate` from `Translation`.

**1c. Outbound.** `OutboundTranslation_GWT.FromSlice(Spec, Translation)` takes `collect` and
`translate` from `Translation`. `whenTranslateMocked` stays. The verbs that run the real
`translate` are phase 2.

**1d. Flows.** `Flow_GWT.AutomationSlice(Spec, Automation)` and
`Flow_GWT.OutboundSlice(Spec, Translation)`, beside the flat steps. The outbound step passes
each event's real source id instead of `""`.

**1e. Inference.** In `GwtInference.ml` and `Util.ml`:
- add a table from kind to body suffix: Automation `_Automation`, inbound and outbound
  `_Translation`, matching the implementation PPX that strips the same suffixes;
- for these three kinds, **when the file has no local module**, include
  `<Kind>_GWT.FromSlice(<Spec>, <Spec><Suffix>)` and open both. Today that case includes the
  flat `Make(<Spec>)`, which cannot compile for these kinds, so nothing that builds now
  changes;
- with a local module, keep today's behaviour. Existing adapters go on compiling until
  phase 5.

**1f. Tests.** Self-tests in `reventless/gwt/tests` for each `FromSlice`, including a
two-source automation. A `test/run.sh` case per kind proves the inference compiles with no
adapter.

### Phase 2: the translation verbs the analysis asks for

They change the same files, and the sidecar in phase 3 has to learn their names. So they land
here rather than in a later release. Details are in
[the analysis, §4.1](../../analysis/testing-translation-slices.md#41-the-scenario-the-slices-contract).

| Change | Where |
|---|---|
| `Capabilities_Fake`: recording fakes for messaging, geocode, secrets and identity provider, scripted answers, `calls()` | `reventless/gwt/src` |
| `givenCapabilities(fakes)`; `whenTranslated` runs the slice's `translate`; a throw becomes `Error` | `OutboundTranslation_GWT.FromSlice` |
| `thenSent(calls)`, `thenNothingSent`, modelled on `SideEffect_GWT.thenExternalCalls` | same |
| `whenExhausted(~lastError) → thenCommand \| thenNoCommand` | same |
| `thenTodoStatus` takes `#Completed \| #Failed \| #Abandoned`; `whenTranslateRetrying` counts attempts as the runtime does (`maxRetries` attempts in all) | same; **a behaviour change**, so `#Pending` stays as a deprecated alias for `#Failed` for one release |
| `whenReceived(json)` decodes through `externalInputSchema`; `thenRefusedInput(reason)`; `thenNotUnderstood(msg)` as the name for `thenTranslateError` (the old name stays); `thenCommands` also round-trips each command through `commandSchema` | `InboundTranslation_GWT.FromSlice` |
| `Flow_GWT.InboundSlice(Spec, Translation)` with `whenReceived(json)`, which publishes the translated commands into the flow's log | `Flow_GWT` |

### Phase 3: the scenario sidecar reads them (gap 1)

**3a. Harvest `testSync`** beside `test`.

**3b. Name the kind.** Add a top-level `"componentKind"` from `Util.derive_gwt_kind`. It is
additive.

**3c. Learn the verbs.** Each verb is mapped onto the existing groups. A new meaning never
reuses `command`, `event`, `input`, `state`, `error` or `noEvent` in *when*. `CheckLifecycleModel`
counts a scenario as a command outcome whenever its *when* is `command`, so reusing it would
turn these scenarios into false outcomes.

| Verb | Group | Kind written | `element` / `values` |
|---|---|---|---|
| `whenCollect`, `whenResolve` after `givenEvent(e)` | when | `event` (the given event **moves** to *when*, as for a view: the event the slice reacts to) | the event constructor |
| `whenSweep`, `whenReacts` | when | `sweep` | `""`; the given events stay in *given* |
| `givenTodo(id, item)` | given | `todo` | `id`; the item's record entries |
| `whenProcess`, `whenTranslated`, `whenTranslateMocked`, `whenTranslateRetrying` | when | `process` | `""` |
| `whenExhausted(~lastError)` | when | `exhausted` | the error text |
| `whenInput(record)`, `whenReceived(json literal)` | when | `input` (unchanged kind) | `externalInput`; the record's entries, **no longer `opaque`** |
| `thenTodos(items)` / `thenScenarioTodos` | then | `todo`, one per item; `noTodo` for `[]` | id; record entries |
| `thenResolved(id)` | then | `resolved` | id |
| `thenCommands(cmds)`, `thenIssuesCommand(s)` | then | `command`, one per command; `noCommand` for `[]` | constructor |
| `thenNoCommand`, `thenIssuesNoCommand` | then | `noCommand` | `""` |
| `thenTranslateError(msg)`, `thenNotUnderstood(msg)` | then | `notUnderstood` | the message |
| `thenRefusedInput(reason)` | then | `inputRefused` | the reason |
| `thenSent(calls)` / `thenNothingSent`, `thenOutbound(items)` / `thenOutboundNothing` | then | `sent`, one per call; `nothingSent` | constructor |
| `thenTodoStatus(id, s)` | then | `todoStatus` | the status name |
| `thenRetryRecorded(n)` | then | `retries` | `n` |

`andThenEvents` starts a second act in one scenario. It cannot be expressed in three groups,
so it goes only into the ordered `steps` (3d).

**3d. Keep the order.** Add an ordered `"steps"` array to every scenario:
`[{group, verb, kind, element, values, via?}]`. `via` is the flow step's module alias
(`Auto` in `Auto.thenIssuesCommand`). *given*, *when* and *then* stay as they are, built from
the same walk, so no reader breaks. A flow, or any chain with two *when* verbs, is then
readable in full, and the last-written-wins loss above is gone for readers that use `steps`.
`SourceReader.collect_steps` already walks verbs in written order, so the walk is shared, not
written twice.

**3e. Readers in core.** In `CheckLifecycleModel.res`:
- a scenario is `opaque` when **no *when* step of a known kind** is present, not when no
  element is present;
- the stale docstring on `thenNoEvent` is fixed;
- the lifecycle outcome rules are unchanged, since none of the new kinds is `command`.

**3f. Tests.** Cases in `src/test_sidecar/test_sidecar.ml` per row of the table. The hand-built
OCaml ASTs nest pipes in the opposite order to ReScript, so every row is also pinned in
`test/run.sh` against real ReScript, including a flow with two `whenCommand`s.

### Phase 4: the model sidecars carry the wiring (gap 3)

**4a. `config`.**
- Accept `let x: t = e`.
- Record these as source text, escaped properly: `Some(literal)` (recorded as the literal), an
  array of literals, and an array of module paths.
- Add the keys `externalSystem`, `sourceNames`, `capabilityNeeds` and `traits`.
- `None` is omitted, so `targetName` absent on an outbound slice still means fire-and-forget.
- Values stay strings, as readers decode them.

**4b. `.wiring.json` for an automation body.** A `@@reventless.automation` file gets its own
sidecar. It is a new suffix, because readers take every `.model.json` for a component
(the same reasoning as [shared-type-sidecar](shared-type-sidecar.md)):

```json
{ "specName": "AutoShipOrder", "stem": "AutoShipOrder_Automation", "file": "…",
  "mappings": [
    { "module": "FromOrderingDcb",
      "source": { "module": "OrderingDcbSource", "sourceName": "\"ordering\"",
                  "events": { "typeName": "event", "shape": "variant", "elements": [ … ] } } } ] }
```

- A mapping whose source module is defined inline gets its `@schema event` encoded with the
  existing `type_entry`.
- A source defined elsewhere is recorded as `"ref": "<module path>"`, for the reader to
  resolve through `.types.json` or that module's `.model.json`.
- The order follows `let mappings`.
- `*.wiring.json` goes into `.gitignore` beside `*.model.json`.

**4c. Out of scope here:** `commandAuthorization` and the other file-level attributes. They are
injected after the capture, and inbound authorization is read three different ways today
([analysis §3.1](../../analysis/testing-translation-slices.md#31-inbound-commandauthorization-is-enforced-only-on-aws-and-only-for-the-first-constructor)).
[Its own plan](an-inbound-translation-is-gated-and-encoded-like-a-command.md) settles that first.

**4d. Tests.** A golden beside `RegisterShelf.model.golden.json` for an outbound spec with
every new key, and one golden `.wiring.json` for a two-source automation.

### Phase 5: release, migrate, document

1. **Release** by the PPX procedure in
   [gwt-sidecar-refs-and-examples](gwt-sidecar-refs-and-examples.md) (R3): build and
   stage the binary, remove every `lib/` (never `rescript clean` over the examples), full root
   build, `packages/reventless-ppx/test/run.sh`, root `pnpm test`, one commit. CI publishes
   and pins; no version is bumped by hand.
2. **Migrate the examples.** Delete the adapter modules in every automation, inbound and
   outbound test of the three shops, and the duplicated adapters in the ordering flow. Move
   SendOrderConfirmation's scenarios to `whenTranslated` once `EmailService` goes through the
   messaging capability. Write the missing AnnounceRecipientContact scenarios. Commit the
   regenerated `.gwt.json` files and the recompiled outputs together.
3. **Document.**
   - [the given-when-then guide](../../../packages/doc/docs-app/given-when-then.md) [§4.8](../../../packages/doc/docs-app/given-when-then.md#48-inboundtranslation_gwt--external--internal-translation) and [§4.9](../../../packages/doc/docs-app/given-when-then.md#49-outboundtranslation_gwt--internal--external-translation): the adapter-free form and the new verbs;
     remove the claim that the real `translate` is tested elsewhere.
   - [`docs/guides/reverse-codegen-pipeline.md` §Sidecars](../../guides/reverse-codegen-pipeline.md#sidecars): `componentKind`, `steps`, the new
     kinds, `.wiring.json`.
   - [given-when-then-specifications §2.5](../../analysis/given-when-then-specifications.md#25-coverage-matrix)
     and the OutboundStep claim in
     [gwt-flow-and-extension-test-kinds](gwt-flow-and-extension-test-kinds.md).
4. **Deprecate** the flat `Make` of the three DSLs and the flat flow steps in their doc
   comments. Remove them one release after the examples have moved.

## Decisions (proposed)

| # | Decision | Why |
|---|---|---|
| D1 | One PPX release for phases 1 to 4 | the inference names functors from the same release; the examples regenerate once |
| D2 | New step kinds never reuse `command`/`event`/`input`/`state`/`error`/`noEvent` with a new meaning in *when* | `CheckLifecycleModel` and the tools key outcome rules on them |
| D3 | The event an automation or collect test reacts to is *when*, not *given* | matches the view convention and the tools' scenario shape; makes these scenarios readable |
| D4 | `steps` is additive; *given*/*when*/*then* stay | no reader breaks; readers move to `steps` when they need order |
| D5 | Automation wiring goes in a new `.wiring.json`, not in `.model.json` | readers take each `.model.json` for a component |
| D6 | The adapter path keeps compiling until phase 5 is done | migrating the examples is not on the release's critical path |

## Open questions

1. **Should `steps` replace the three groups in the end?** Leaning: yes, in a later release,
   once both repos read `steps`.
   **Recommendation:** yes. The groups are the lossy view (last *when* wins, no second act), and
   as long as they are written, a new reader will reach for them. So:
   - move `CheckLifecycleModel` onto `steps` in this plan (3e), so core needs nothing more;
   - drop the groups one release after the tools' companion plan reads `steps`, the same
     window as removing the flat `Make` (phase 5.4).
2. **`whenSweep` given events from several sources:** is `Mapping(M).event(e)` readable
   enough, or should `givenEvents` take `(sourceName, json)` pairs? Leaning: the typed wrapper;
   the pairs lose the constructor the sidecar records.
   **Recommendation:** the typed wrapper. Besides keeping the constructor, a typo in a source
   name or a payload that no longer matches the event is a compile error, not a to-do that
   silently never appears. `event(e)` should encode through the source's `sourceEventSchema`,
   so the sweep still runs the real decode-and-route path. Add a raw
   `(sourceName, json)` form only when a test needs a malformed or unknown-source payload, and
   name it for that (`givenUndecodable…`), so the sidecar can tell the two apart.
3. **Does `thenScenarioTodos` assert the full to-do view or only the rows it names?** It is
   unchanged here; record what it does in the guide.
   **Recommendation:** it asserts the full view, and it should stay that way. Today it is
   `thenTodos(scenario.todos, expected)`: exact equality on every to-do still open after the
   sweep (resolved ones removed), **order included**
   ([Automation_GWT.res](../../../reventless/gwt/src/Automation_GWT.res)). Exact is the right
   default: a sweep that opens an extra to-do is the bug these tests exist to catch. Record in
   the guide that the comparison is ordered, in the order the given events collected them.
   The multi-source sweep in 1a must keep that order by routing each event in turn, not
   grouping them by mapping. If a "contains these rows" check is ever needed, add it under its own
   name rather than loosening this one.

## As built

- **The adapter test.** For these three kinds a file keeps the flat `Make` only when it declares a
  `module X = { … }`. A module alias or a functor application (`module Orders = Mapping(…)`) does
  not count, so a migrated test can name helpers. The two injected opens carry
  `@warning("-33")`: a translation test often names nothing from its body.
- **An automation's `whenExhausted` takes no `~lastError`**, because its `onExhausted` has none.
  Both are piped from `givenTodo`.
- **`whenTranslated` is one attempt.** `whenTranslateRetrying` makes the runtime's `maxRetries`.
  `retries` is the row's `retryCount`, which gives the same numbers as before; only the attempt
  count and the statuses moved.
- **The sweep follows the runtime's to-do list**: the first writer of an id wins, and a resolve
  completes only a row that already exists. The flat sweep dropped an id resolved anywhere in the
  stream.
- **Flow groups.** *when* is the last when-verb, as before, and the flow verbs are now known. So
  the hybrid ordering flow's *when* is `sweep`, not `ShipOrder`, and that scenario no longer
  counts as a ShipOrder outcome. Both commands are in `steps`.
- **`.wiring.json` also carries the source's other `@schema` types** (`types`), which its event
  fields name.
- **SendOrderConfirmation keeps `whenTranslateMocked`.** It still calls a mailer directly, and
  routing it through messaging would add a capability need to the DCB example's deploy.
- **NotificationIntake keeps 2 unreadable scenarios.** They check the rule table and use no GWT
  verb.
- **The source reader** spanned the unit argument of `f()` as the `)` alone; it now reaches back
  to the `(`.

## Acceptance

- `CheckLifecycleModel --json` lists no `opaque` corpus for an automation, inbound or outbound
  test in the three example shops. Today these are 42 scenarios, plus the `testSync` ones that
  will now be harvested.
- No example test of these kinds defines an adapter module. The ordering flow uses
  `Flow_GWT.AutomationSlice`.
- GeocodeCustomerAddress's `.model.json` config has `targetName`, `sourceNames`,
  `externalSystem` and `capabilityNeeds`. ImportProduct's has `externalSystem`.
  AutoShipOrder has a `.wiring.json` naming its mapping and source events.
- The hybrid ordering flow's sidecar records both `PlaceOrder` and `ShipOrder` in `steps`.
- The full build, `packages/reventless-ppx/test/run.sh`, `dune test` in the PPX and root
  `pnpm test` all pass.

## Not in this plan

- Inbound `commandAuthorization` the same at every door, and inbound commands encoded with
  their schema: [an-inbound-translation-is-gated-and-encoded-like-a-command.md](an-inbound-translation-is-gated-and-encoded-like-a-command.md).
- Idempotency of repeated deliveries, in and out.
- The webhook URL ([Backlog/webhook-infrastructure.md](../Backlog/webhook-infrastructure.md)).
- The tools' readers (companion plan in reventless-tools).
