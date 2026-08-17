# Plan: read the lifecycle machine off the GWT corpus, and check `@transition` against it

**Status.** PROPOSED 2026-08-17. Nothing built. Phase 0 is a one-hour
verification that gates the rest; Phases 1 and 2 are independently shippable and
Phase 1 is useful on its own.

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
   plugin package. Emit the harvested model as a committed ReScript artifact from
   `generate-plugin` (the same generated-and-committed contract `src/Plugin.res`
   already has), and let `buildStructure` consume that.
4. **Retire the level heuristic** if Phase 1 reports no disagreement, or record
   why it is kept.

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
- **PPX**: Phase 0 may touch `SidecarEmit.ml` only. No annotation syntax changes,
  so no example resweep.
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
