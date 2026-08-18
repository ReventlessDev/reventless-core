# Plan (Backlog): Full Admin Read-Model / Aggregate Harmonization

**Status:** Backlog (not started)

**Depends on:** [plugin-history-parity-gap.md](../plugin-history-parity-gap.md) Part 1
(admin read-model query SDL generated from the spec) — this plan is "Part 3" of that
effort, deliberately deferred because it carries cross-repo consumer impact.

**Analysis:** [plugin-aggregate-readmodel-vs-normal-harmonization.md](../../analysis/plugin-aggregate-readmodel-vs-normal-harmonization.md),
[plugin-history-view-design.md](../../analysis/done/plugin-history-view-design.md) (§3.3, §7, §8).

---

## Goal

Eliminate the remaining divergences between **admin** components (the Plugin
aggregate + admin read models in `reventless-core/src/admin/`) and **ordinary**
components, so admin components are assembled by the *same* pipeline — no hand-rolled
fragments, no bespoke Lambdas, no hand-written structure metadata. The parity-gap
plan closes the SDL-generation half; this finishes the job.

Three independent work items, each shippable on its own:

1. **Retire `Platform_UIFragments_Lambda`** — serve `UIFragmentRegistry` through the
   standard auto-generated read-model path.
2. **Derive the lifecycle metadata** from `@transition` annotations instead of
   hand-writing it in `Platform_Admin_Structure`.
3. **(Maximal) Route admin read models entirely through the ordinary component
   pipeline** — the full version of the parity-gap plan's Part 1.

---

## Progress

| Item | Status | Notes |
|---|---|---|
| 3.1 — retire `Platform_UIFragments_Lambda` | ⬜ backlog | **cross-repo:** SDL shape flat `[X!]!` → `Connection` breaks the host-shell consumer |
| 3.2 — derive lifecycle metadata from `@transition` | ✅ done | fixed three drifts; SDL unchanged |
| 3.3 — route admin read models through the ordinary pipeline | ⬜ backlog | largest; subsumes parity-gap Part 1's minimal form |

---

## Item 3.1 — Retire `Platform_UIFragments_Lambda`

Today `UIFragmentRegistry` is a single-key read model served by a **dedicated scan
Lambda** ([`Platform_UIFragments_Lambda.res`](../../../reventless/reventless-aws/src/adapter/Api/Platform_UIFragments_Lambda.res))
that returns a flat `Platform_UIFragments: [Platform_UIFragmentEntry!]!`. Analysis
§3.3 establishes this is a *shape* workaround, not a capability need.

**Work:**
- Expose `UIFragmentRegistry` via the standard `Single_Stream` builder + generated
  admin SDL (from parity-gap Part 1), dropping the Lambda, its DataSource, IAM, and
  the `Platform_UIFragments` hand-stitched SDL field.
- Local: drop the bespoke `Platform_UIFragments` resolver; covered by the generic
  admin resolver registration.

**Risk / blocker (why this is backlog):** the field changes shape from a flat array
to a read-model **Connection** (`edges { node … } pageInfo`). The **host-shell
consumer in `reventless-ui`** reads `Platform_UIFragments` as a flat list to load
remote entries. Retiring the Lambda therefore requires a **coordinated cross-repo
rollout**:
- Option (a): update the host-shell to consume the Connection shape, then retire the
  Lambda (two-repo, ordered deploy).
- Option (b): keep a flat-list compatibility alias field during transition.

Do not start until the host-shell change is scheduled together.

**Verification:** `Platform_UIFragments` (or its replacement) returns the same data;
the host-shell still loads UI fragments; UIFragment live-updates (Source B) still
fire.

---

## Item 3.2 — Derive lifecycle metadata from `@transition` — ✅ done

The Plugin aggregate's lifecycle metadata was **hand-written** in
[`Platform_Admin_Structure.res`](../../../reventless/core/src/admin/Platform_Admin_Structure.res),
not derived from annotations on the spec like every other aggregate (harmonization
analysis §1).

**The annotation is `@transition`, not `@allowedStates`.** This item was written
before [lifecycle-transition-annotation.md](../lifecycle-transition-annotation.md)
replaced the `@allowedStates` / `@targetState` pair with the single `@transition`
attribute; the removed attributes are now a hard PPX error. The distinction matters
here rather than being cosmetic: `@allowedStates` carried only the from-set, and it
is the **target** that AutoUI needs to draw an edge.

**Byte-stability was the wrong acceptance criterion**, because the hand-written copy
was wrong in three ways at once, and preserving it would have preserved all three:

| Drift | Symptom |
|---|---|
| `Activate` declared `["Inactive"]` | `PluginBehavior.decide` also accepts `Retired`; the archive looked one-way |
| every `targetState` was `None` | `AutoStatusTransitions.declaresNoMove` reads `(Some(from), None)` as the positive claim that the command does not move the row — so the Plugins lifecycle board drew four states and **no edges at all** |
| `Retire` had no `commandDef` | `Platform_Plugin_Retire` is a live mutation; the `Retired` column read "No commands available" and nothing pointed into it |

**Done:**
- `PluginSpec.command`'s three admin variants carry `@transition`, naming the same
  edges `PluginBehavior.decide` accepts.
- `Platform_Admin_Structure` reads `allowedStates` / `targetState` off
  `PluginSpec.commandSchema` through `ApiAllowedStatesHelpers` /
  `ApiTargetStateHelpers` — the same helpers `Plugin_Structure.toCommandDef` uses —
  and composes `mutationField` the way `PluginBaseFragment` composes the field it
  generates, so the two cannot name it differently.
- `retireCommand` added to `pluginAggregate.commands`.

**Verified:** full build zero warnings; 346 suites / 3453 tests green;
`pnpm run check:graphql` unchanged (the `Plugin_Retire` mutation already existed in
the SDL — only the structure metadata was missing it). Emitted defs:

```
Activate   | from: ["Inactive","Retired"]                  | to: "Connected" | Platform_Plugin_Activate
Deactivate | from: ["Connected","Disconnected"]            | to: "Inactive"  | Platform_Plugin_Deactivate
Retire     | from: ["Connected","Disconnected","Inactive"] | to: "Retired"   | Platform_Plugin_Retire
```

**Left for 3.3:** the `@noApi` protocol variants (`Heartbeat`, `Connect`,
`Disconnect`, `Redetect`, `ReportIncompatibility`) still have no `commandDef`. The
ordinary path emits them with `apiExposed: false` for the event-graph badge; here
they are simply absent. Harmless for the lifecycle board, which only reads
Instance-level exposed commands, and it falls out of routing the admin through the
generic pipeline rather than being worth a fourth hand-written record.

---

## Item 3.3 — Route admin read models through the ordinary component pipeline

The parity-gap plan's Part 1 does the **minimal** fix (emit `<single>Items` +
`By<Index>` for admin fragments). The maximal version routes admin read models
(`Plugins`, `PlatformEventGraph`, `UIFragmentRegistry`, `PluginHistory`) entirely
through the same composition path ordinary plugins use (`Plugin_Structure.make` +
`GraphQL_FragmentGenerator` + the generic read-model builder), deleting the
hand-maintained `PluginBaseFragment.queryEntries` / `AdminApi.baseFragment` query
assembly outright.

**Work:**
- Treat the admin platform as an ordinary plugin for structure/SDL purposes (or a
  thin shim that feeds its specs into the same pipeline).
- Remove the parallel admin SDL/registry code once the generic path covers it.

**Risk:** largest blast radius (touches the admin schema surface end-to-end,
deploy-verified). Only worth doing if several admin read models accumulate or the
maintenance cost of the parallel path becomes painful. Subsumes 3.1's SDL half.

**Verification:** all admin queries (`Platform_Plugin(s)`, `Platform_PlatformEventGraphs`,
`Platform_UIFragments`/replacement, `Platform_PluginHistory*`) resolve identically;
AutoUI renders all admin views; no hand-rolled admin fragment code remains.

---

## Sequencing

Independent items; suggested order if pursued:

1. ~~**3.2** first (low-risk, self-contained, immediate cleanup).~~ Done.
2. **3.1** when a coordinated `reventless-ui` host-shell change can be scheduled.
3. **3.3** last (or instead of the parity-gap plan's minimal Part 1 if tackled up
   front) — the consolidation that makes 3.1's SDL half fall out for free.

Each item: full build (zero warnings) + `pnpm test` green before committing; show the
commit message and get approval; do not push.
