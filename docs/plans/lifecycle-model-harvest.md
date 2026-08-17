# Plan: read the lifecycle machine off the GWT corpus, and check `@transition` against it

**Status.** 2026-08-17. **Phase 0 done** (came back negative — see §2), **Phase 1
done and green**, Phase 2 not started. Phases 1 and 2 are independently shippable
and Phase 1 is useful on its own.

**Goal.** Derive each command's `allowedStates` / `targetState` /
Collection-vs-Instance from the GWT scenarios that already exist, and report
three verdicts against the authored `@transition` annotations: **confirmed**,
**contradicted** (error), **unverified** (warning). Phase 2 then publishes the
derived values, with the annotation demoted from *claim* to *coverage
obligation*.

**Relates to:**

- [`docs/analysis/lifecycle-model-from-gwt-corpus.md`](../analysis/lifecycle-model-from-gwt-corpus.md)
  — the argument and the evidence. This plan implements its §7.
- [`docs/analysis/given-when-then-specifications.md`](../analysis/given-when-then-specifications.md)
  §5.6 — the closed-world gate, which constrains the *generation* pipeline and is
  explicitly out of scope here.
- [`docs/plans/lifecycle-transition-annotation.md`](./lifecycle-transition-annotation.md)
  — built `@transition` and its name check. This plan adds the behaviour check
  that plan's §6 called for and could not build.
- [`docs/analysis/rejected/command-lifecycle-guard-defaults.md`](../analysis/rejected/command-lifecycle-guard-defaults.md)
  — the four options this supersedes.

---

## Why

`@transition` is authored, unenforced, and unchecked against behaviour. The name
check added by the prior plan proves the *state names* exist; nothing proves the
*claim* — that `decide` actually refuses elsewhere. Two live consequences in the
shipped examples:

- **`Customer.Reactivate`** declares `([Customers.Deactivated]) => Customers.Active`
  and has **zero** GWT scenarios. Nothing has ever exercised the edge it claims.
- **`Customer.Reactivate` also disagrees with `decide` today.** The behaviour has
  `| (Active(_), Reactivate) => Ok([])` — accepted on an active customer, while
  the annotation says the command belongs only on a deactivated one. Harmless
  (the annotation hides a no-op button), but it is exactly the class of drift
  nothing detects.

The corpus already answers this. Transcribing existing scenarios reproduces the
authored annotations exactly, in both the easy and the hard case:

| Component | Derived from scenarios | Authored |
|---|---|---|
| `Customer.UpdateEmail` | `["Active"]`, no target | `@transition([Customers.Active])` |
| `Customer.Deactivate` | `["Active"]` → `Deactivated` | `@transition(([Customers.Active]) => Customers.Deactivated)` |
| `ChangeProductPrice` | `["Listed", "Archived"]`, no target | `@transition([Products.Listed, Products.Archived])` |

The third is the case the rejected analysis called the counter-example that
defeated a retirement-based default: a command deliberately legal on a *retired*
row. The corpus gets it right because it reads behaviour rather than a proxy.

---

## Non-goals

- **The closed-world gate.** It belongs to the generation pipeline (GWT analysis
  §5.4), which does not exist — there is no CLI runner and Stages A–E are
  unbuilt. Recorded there as a binding constraint on that future work; nothing
  here depends on it.
- **Generating `decide` / `evolve` / `project`.** Out of scope entirely.
- **Removing `@transition`.** The annotation stays. Its job changes.
- **A multi-target wire shape.** All ten arrow-form annotations in the examples
  have one target. Phase 1 will *report* a contradiction if any command is
  observed landing in two states, which is the signal to spend that change. See
  Deferred.
- **Touching `reventless-ui`.** Phase 2 adds a field; consuming it is that repo's
  work.

---

## §1 — The surface

### What is harvested

The PPX already emits a `<Stem>.gwt.json` sidecar beside every
`@@reventless.gwt` file when `REVENTLESS_EMIT_SIDECAR=1`
([SidecarEmit.ml](../../packages/reventless-ppx/src/ppx/SidecarEmit.ml),
`maybe_emit_gwt`). No PPX change is required for command slices. Shape, from
`ChangeProductPrice_GWT.gwt.json`:

```json
{ "title": "repricing an archived product is allowed",
  "given": [{"kind":"event","element":"ProductAdded", "values":[...]}, ...],
  "when":  [{"kind":"command","element":"ChangeProductPrice", "values":[...]}],
  "then":  [{"kind":"event","element":"ProductPriceChanged", "values":[...]}] }
```

The sidecar is a **compile-time** artifact. That is the load-bearing property:
the harvest is a build step like every other input to `buildStructure`, not a
consumer of test *execution*. Deploy-time metadata must not depend on a test run
— a deleted test file would otherwise silently change a production command menu.

Sidecars are gitignored (`.gitignore:86`), so the harvest **drives its own build
with the flag set** rather than relying on one having happened. The 41 sidecars
currently on disk against 103 `_GWT.res` sources are the residue of a partial
build, not a coverage statement.

### Rule 1 — labelling the from-state

`given` is a list of events, not a state name. Label it by folding a per-view map
`event element → lifecycle field value`, read off that view's projection corpus.
For `Customers`: `Registered → Active`, `Deactivated → Deactivated`,
`Reactivated → Active`, every other event → unchanged. Then `[Registered,
Deactivated]` folds to `Deactivated`, `[Registered]` to `Active`, and `[]` to
**no row at all**.

Deriving the map from the corpus rather than executing the compiled `project`
keeps the whole harvest a pure JSON-to-JSON transform, with no module loading and
no runtime. It also fixes an ordering constraint: a view's scenarios must be
harvested before the command slices that reference it.

### Rule 2 — effect, not acceptance

The discriminator is already in the sidecar, verified against
`ChangeProductPrice_GWT.gwt.json`:

| `then` | DSL form | In `allowedStates`? | Edge? |
|---|---|---|---|
| `[{"kind":"event"}]` | `thenEvent(…)` | **yes** | if the lifecycle label moves |
| `[]` | `thenNoEvent` | **no** | no |
| `[{"kind":"error"}]` | `thenError(…)` | **no** | no |

Keying on *effect* is what makes the derivation match the annotations. Keying on
*acceptance* would not: the repo's `Ok([])`-on-no-change convention means
`decide` accepts commands a menu should not offer, and `Reactivate` on an active
customer is the live example.

### Rule 3 — level

A command whose successful scenarios all start from **no row** is
Collection-level; one that needs a row is Instance-level. This replaces the
prefix guess over
`["Add", "Create", "Register", "Open", "Initialize", "Submit", "Start", "Place"]`
in `Plugin_Structure.commandLevelAndId` — which misclassifies `Enroll`,
`Provision`, `Onboard`. Phase 1 reports disagreements; Phase 2 may adopt the
derived value.

### The three verdicts

Per declared edge, against the harvested relation:

| Verdict | Meaning | Severity |
|---|---|---|
| **confirmed** | a scenario exhibits the edge | — |
| **contradicted** | scenarios exhibit a different edge | **error** |
| **unverified** | no scenario covers it | **warning**, with a count |

Same severity split `checkDeclaredTransitions` already uses. A *derived* edge
with no declaration is reported as **undeclared** — informational in Phase 1,
since silence is not yet a claim.

---

## §2 — Phase 0: does the sidecar cover the projection DSL?

**Gating, small.** Rule 1 needs the lifecycle map, which comes from
`Projection_GWT` / `MultiSourceProjection_GWT` / `StateViewSlice_GWT` scenarios —
whose `then` is `thenState(record)`, not `thenEvent`. Whether `SidecarEmit`
records those field values is **unverified**: no projection sidecar exists on
disk to inspect, because the flag was off for that build.

1. Run `REVENTLESS_EMIT_SIDECAR=1` over `examples/online-shop-hybrid/ordering`
   and inspect `Customers_GWT.gwt.json`.
2. If `then` carries the `thenState` field values (including `accountStatus`) —
   nothing to do, proceed to Phase 1.
3. If it does not, extend `SidecarEmit.maybe_emit_gwt` to record them. This is
   the only PPX change the plan may need; per the PPX convention it ships in one
   commit with a version bump, and republishing is decoupled external-consumer
   housekeeping.

Also confirm here that the emit fires for **every** DSL kind, by counting
sidecars against `_GWT.res` sources after a clean full build with the flag. A
kind that emits nothing is a blind spot the harvest would not announce.

### Outcome — negative, and wider than one function

The projection corpus was recorded as `given` and nothing else: every scenario in
every view file came back with an empty `when` and `then`. Four separate gaps,
all in `SidecarEmit`:

1. **The projection verbs were not in `step_names`.** `whenEvent` / `thenState` /
   `thenStateWithId` are how every view DSL is written, and none was listed — so
   the walk found no when-step and no then-step to record.
2. **Lifecycle values were dropped.** A lifecycle case is a payload-less
   constructor, and `example_of_expr` had no case for one. `shelfStatus: Listed`
   recorded nothing, so even a recorded `thenState` would have carried no state.
   Emitted now as a new `enum` kind — see the note under Interference.
3. **A multi-source read model emitted no sidecar at all.** `Customers_GWT.res`
   wires one `Make` module per source mapping, so it has no single Spec to
   include and carries no `@@reventless.gwt`; its calls are qualified
   (`CustomerGwt.thenState`) besides. The emit now also keys off the `_GWT` /
   `GwtTest` filename, and step names match on their last segment.
4. **A scenario that named a value first recorded nothing.** `collect_applies`
   did not walk into `Pexp_let`, so a test body that binds a date range before
   the chain looked like a scenario asserting nothing.

After the fix, every StateChangeSlice, Aggregate, StateViewSlice and ReadModel
scenario across the three examples records a when and a then. The 63 that still
do not are all in DSLs this harvest does not read — Extension, ExtensionPoint,
Automation, Inbound/OutboundTranslation, Mapping, Flow.

---

## §3 — Phase 1: the checker, report-only

**Nothing published changes.** This phase is worth shipping alone: it catches the
`Reactivate` gap and any contradiction on the day it lands.

### Where it lives

`scripts/CheckLifecycleModel.res` → `pnpm run check:lifecycle`, modelled on
[`scripts/CheckGraphqlContract.res`](../../scripts/CheckGraphqlContract.res),
which is the exact precedent: a ReScript script compiled to `.res.mjs`, run from
the repo root, booting the hybrid example's local platform. Reuse its shape —
including its `--update` golden flow.

### Pipeline

1. Build with `REVENTLESS_EMIT_SIDECAR=1`; collect `**/*.gwt.json`.
2. Group by component; build the per-view lifecycle map (Rule 1).
3. Harvest the `(fromState, command, outcome, toState)` relation (Rules 2, 3).
4. Read the **declared** edges by reflecting `pluginStructure` through
   `reventless-local` — `commandDef.allowedStates` / `.targetState` / `.level`.
   No `.res` parsing; this is the same reflection route the domain-graph work
   settled on.
5. Emit the verdicts, and a tracked golden of the derived model so a change shows
   up as a reviewable diff in the PR that causes it — the same contract the
   GraphQL goldens hold, refreshed in the commit that moves them.

### Acceptance

- Reproduces the three §Why rows exactly.
- Reports `Customer.Reactivate` as **unverified**.
- Zero **contradicted** across all three examples, or each one explained. A
  contradiction here is a real finding about the examples, not a bug in the
  checker — treat it as such before adjusting rules.
- Runs in CI. Warnings do not fail the build; contradictions do.

### Outcome — met, and three rules earned their keep

All four hold. `UpdateEmail` derives `["Active"]`, `Deactivate` derives
`["Active"] → Deactivated`, and `ChangeProductPrice` derives
`["Archived", "Listed"]` — the case a retirement-based default could not get
right. `Reactivate` reports unverified on both halves of its annotation.

The first run reported two contradictions and a wall of level disagreements. Per
the acceptance note they were treated as findings first, and all of them were:

- **Two real corpus holes.** `ShipOrder` looked like it shipped a *cancelled*
  order, and `UnarchiveProduct` like it unarchived a *listed* one. Both because
  the view had never been shown the event: `Orders` had no `OrderReopened`
  scenario and `Products` had none for the archive trio, so the histories folded
  one event short. The projections fold all four correctly — only the scenarios
  were missing. Added, and both contradictions went away. This is the same class
  of drift as an event one slice folds and its sibling ignores.
- **A history has to belong to one row.** A slice's `given` names whatever the
  decision needs, including this entity's *other* rows: "placing a second order"
  sets up `o1` and then places `o2`. Folding that into `o2`'s state made a
  creating command look like a guarding one. The fold now keeps only setup
  carrying the command's own id, and keeps events that name no id at all —
  which is the normal shape for an aggregate.
- **Silence beats a confident wrong answer.** Where a writable's linked views
  declare no lifecycle field, every history folds to "no row" and every command
  looks like it creates one. That produced 36 bogus level disagreements. The
  level is now left blank and the command's claims reported as unverified,
  naming the missing lifecycle field as the reason.

Two findings remain, both correct: `Reactivate` (unverified, no scenarios) and
`Customer.SetLocation` / `Customer.MarkAddressUnresolvable` taking effect from
`Active` with no `@transition` written.

**The harvest drives one root build, not one per plugin.** Six per-plugin builds
orphan the in-source test outputs of packages in their dependency graphs, which
is not a build failure but a jest project that discovers nothing and passes. It
runs the same ordered chain as `pnpm run build`.

---

## §4 — Phase 2: publish the derived model

1. **Add `allowedStatesSource: "declared" | "derived"`** to `commandDef`,
   alongside the existing `labelFieldSource` / `idFieldSource` provenance rungs
   in `Plugin_Structure`. Without it the state-machine diagram in `reventless-ui`
   cannot rank an inherited edge against an authored one — it draws
   `allowedStates: None` commands outside the state graph today.
2. **Precedence — decided:** where a corpus exists, derived wins and is tagged
   `"derived"`. Where none exists, the annotation stands alone, tagged
   `"declared"`. A component with neither publishes `None`, exactly as now. This
   keeps a plugin with no tests working unchanged rather than emptying its menus.
3. **Feed the model in as data, not as a filesystem read.** `buildStructure`
   must not read `tests/**` at deploy time — tests are not published with a
   plugin package. Emit the harvested model as a committed ReScript artifact (the
   same generated-and-committed contract `src/Plugin.res` already has), and let
   `buildStructure` consume that.

   **Written by `check:lifecycle:update`, not by `generate-plugin`.** The
   generator runs in `prebuild`, and the sidecars are produced by the build it
   precedes — so a generator-written artifact is always one build stale, and on a
   cold clone the first build has no sidecars at all. `check:lifecycle` already
   drives its own sidecar build; having it write the artifact beside the golden
   keeps the two refreshed by one command and reviewed in one diff.
4. **Retire the level heuristic.** Phase 1 reports no disagreement wherever the
   corpus can label a history, so `commandLevelAndId`'s name-stem guess has
   nothing left to contribute where a corpus exists — but note it also supplies
   `aggregateIdField`, which the corpus does not, so only the level half goes.
5. **`allowedStatesSource` must be optional and js_nullable.** A required field
   added to `pluginStructure` wedges registration for any plugin whose persisted
   definition predates it.

---

## §5 — Risks

- **Phase 0 comes back negative** and the projection sidecar needs a PPX change.
  Contained: one function, one version bump, and the rest of the plan is
  unaffected.
- **The lifecycle map is ambiguous** when a view has two sources writing the same
  lifecycle field (`Customers` is mixed-source). Mitigation: build the map only
  from mappings whose scenarios touch the `@lifecycle` field; report ambiguity
  rather than picking.
- **Sparse corpora produce a narrow model.** This is why Phase 1 is report-only
  and why precedence in Phase 2 leaves an annotation-only component untouched.
  Publishing a derived-narrow set over a correct declaration would be the
  missing-button failure the rejected analysis warned about.
- **The examples are the only corpus.** Every rule here is validated against
  three shop examples. A rule that holds for them may not generalise; the golden
  makes the next counter-example visible rather than silent.

## §6 — Interference

- **`generate-plugin`** gains an output in Phase 2. Its prebuild contract and the
  committed-`Plugin.res` convention are unchanged.
- **PPX**: Phase 0 touched `SidecarEmit.ml` and the one line in `ReventlessPpx.ml`
  that calls it. No annotation syntax changed, so no example resweep, and the
  compiled output is identical — the emit is still gated on
  `REVENTLESS_EMIT_SIDECAR`.

  **The sidecar's `exampleValue` gained an `enum` kind**, and that is a wire
  change for whoever reads sidecars back. A reader that decodes the kinds
  exhaustively will not recognise it. The alternative — writing a constructor as
  the existing `string` kind — was rejected: it renders `shelfStatus: "Listed"`
  where the author wrote `shelfStatus: Listed`, which is a record literal that
  does not compile, and a wrong value is worse than an unknown one. Republishing
  the PPX and updating such a reader is the usual decoupled housekeeping.
- **CI**: one new root script, same shape as `check:graphql` and
  `check-jest-projects.mjs`.
- **`reventless-ui`**: Phase 2 adds a field. Nothing breaks if it is ignored.

## §7 — Deferred

- **Multi-target edges.** The corpus yields a relation, so the model handles a
  branching command natively; only the *published* `targetState: option<string>`
  cannot carry it. Deferred until Phase 1 reports a real instance. Note for
  whoever picks it up: the honest shape is an edge list, not `array<string>`
  beside `allowedStates: array<string>` — parallel arrays read as a cross product
  and would assert transitions that do not exist.
- **`@transition` as an obligation generator** — a payload that expands to
  refusal obligations (e.g. "every retired state") so adding a lifecycle state
  produces an unmet obligation rather than a silently narrower menu. Needs
  Phase 1's verdict machinery first.
- **The closed-world gate**, with the generation pipeline.
