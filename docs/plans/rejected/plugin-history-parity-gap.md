# Plan: Admin Read-Model Parity Gap → PluginHistory Redesign

> **⛔ SUPERSEDED / REJECTED (2026-06-20).** This plan's central deliverable —
> shipping **PluginHistory as a built-in admin read model** in core (Part 2) —
> landed (`8a1d86ee3`) and was then **removed** by `0de749a7b`
> (*"refactor(admin): remove built-in event-graph and plugin-history read
> models"*, on `alpha`). The architectural decision changed: core admin no
> longer ships these views — a platform that wants them registers its own read
> models. **What survives:** Part 1's generic admin-query SDL mechanism
> (`Api_Naming.adminField` in `PluginBaseFragment`), still used for the
> remaining `Plugins` admin RM. Retained for the historical reasoning only.

**Date:** 2026-06-18

**Analysis:** [docs/analysis/plugin-history-view-design.md](../analysis/done/plugin-history-view-design.md)
(see also [plugin-aggregate-readmodel-vs-normal-harmonization.md](../analysis/plugin-aggregate-readmodel-vs-normal-harmonization.md))

---

## Goal

Make `PluginHistory` (the per-version lifecycle timeline) a **visible admin read
model** — *without* custom admin Lambdas and *without* a flat-key workaround. The
deploy failure showed the real blocker is a framework parity gap: admin read models
get a **hand-rolled** GraphQL surface (`single` + `list` only) instead of the
**spec-generated** surface ordinary read models get (`single` + `list` +
`<single>Items` + `By<Index>` + filter/sort). So:

1. **Close the parity gap first** (framework) — generate admin read-model query SDL
   from the spec via `GraphQL_FragmentGenerator`, in lockstep with the shared
   resolver layer. Paid once; benefits every admin read model.
2. **Then redesign `PluginHistory` on top** — composite key (efficient per-plugin
   timeline) exposed through the standard auto surface, GSIs added only as specific
   dashboards need them. No Lambda, no flat-key replacement.

Non-goal (separate follow-up): full admin/normal harmonization (retiring the
`UIFragments` Lambda, `allowedStates` derivation) — tracked but out of scope here
because the `UIFragments` shape change is a cross-repo (host-shell) consumer impact.

---

## Progress

| Step | Status | Notes |
|---|---|---|
| Step 0 — stabilize the branch (revert to Internal) | ⬜ **skip** | only needed for an *interim* green deploy; not deploying between Part 1 and Part 2, so skip — Part 1 makes the already-committed visibility change valid |
| Part 1 — close the admin read-model parity gap | ✅ done | core: admin `queryEntries` derive `subIdField`/`indexQueries` from each spec (`PluginBaseFragment.res`) → generator emits `<single>Items`/`By<Index>`; AWS resolvers already matched (no change); local: generic `registerAdminItemsAndIndexResolvers` wired into all 3 admin-query sites (`reventless-local/Platform.res`). SDL verified: `Platform_PluginHistoryEntryItems` now emitted, Plugins/EventGraph byte-stable. Core 418 + local 424 tests green, zero warnings. |
| Part 2 — finish PluginHistory visibility (composite key, standard surface) | ✅ code-complete | config already committed in `8a1d86ee3`; Part 1 made it valid. Verified: projection uses `UpdateMultiState`, `Platform_Admin_Structure.pluginHistoryReadModel.queryField` == `listFieldName`, single field now `(id, transitionKey)` matching the AWS `queryByIdSort` resolver (latent mismatch fixed). **Remaining (user ops):** AWS cleanup (delete orphaned EventSourceMapping `be58fe31`) + single redeploy → green; runtime-verify timeline on deploy. |
| Part 2b — GSIs for dashboards (optional, incremental) | ⬜ backlog | detailed separate plan → [Backlog/plugin-history-indices-and-dashboards.md](Backlog/plugin-history-indices-and-dashboards.md) |
| Part 3 — full harmonization (retire UIFragments Lambda, allowedStates) | ⬜ backlog | consumer-impacting; separate plan → [Backlog/admin-readmodel-full-harmonization.md](Backlog/admin-readmodel-full-harmonization.md) |

**Deploy once, at the end.** No interim deploy between Part 1 and Part 2, so the
branch stays red until both land — that's fine and expected. One deploy after Part 2
(with the AWS cleanup) goes green.

---

## Current state (what's deployed / committed)

- `alpha` carries: `9e480ac0` (d2 style), `8a9546b03` (**dispatch fix — good, keep**),
  `8a1d86ee3` (**PluginHistory visibility — broken on deploy**).
- The broken commit makes `PluginHistory` a composite-key, `Single_Stream`,
  auto-resolver read model → the deploy fails with:
  - `No field named Platform_PluginHistoryEntryItems` (parity gap), and
  - an EventSourceMapping 409 (`be58fe31`) from the `NoResolver_Stream →
    Single_Stream` builder swap.
- AWS leftovers from the failed deploy: the `PluginHistory-…` table and the orphaned
  StateTopic mapping `be58fe31`.

---

## Step 0 — Stabilize (SKIPPED)

This step only buys an *interim* green deploy (revert PluginHistory to `Internal`,
keep the dispatch fix). Since we deploy **once, after** Part 1 + Part 2 — not in
between — it's pure churn (revert then immediately un-revert) and is **skipped**.

Consequence of skipping: the branch deploy stays red until Part 1 lands (Part 1 is
exactly what makes the already-committed visibility config valid). Acceptable — no
deploy is attempted in that window. The dispatch fix ships together with Part 1+2.

---

## Part 1 — Close the admin read-model parity gap

**Outcome:** admin read models emit, from their spec, the same query fields ordinary
read models do — `<single>Items` (sub-id) and `By<Index>` (GSI) — so the SDL is in
lockstep with `QueryDbResolvers_{AppSync,GraphQL}`.

### 1.1 Map the two paths (investigation)

- Ordinary: where the plugin pipeline calls `GraphQL_FragmentGenerator` to emit a
  read model's query fragment (`deriveItemsQueryField`
  [GraphQL_FragmentGenerator.res:298], `spec.indexes` [:220], filter/sort capability).
- Admin: `PluginBaseFragment.queryEntries` (`querySchemaEntry`: specName,
  singleFieldName, listFieldName, returnTypeName, stateSchema, authorization,
  excludeFields) → `AdminApi.baseFragment` → `GraphQL_Stitcher`. Confirm this is the
  *only* place admin query SDL is assembled, and that it currently emits just
  `single` + `list`.

### 1.2 Core — generate admin query SDL from the spec

- Replace the hand-rolled per-entry SDL in `PluginBaseFragment` / `AdminApi.baseFragment`
  with a call to `GraphQL_FragmentGenerator` for each admin read model, driven by the
  spec's `stateSchema` + `subIdConfig` + `config.indexes`, while preserving the admin
  prefix naming (`Api_Naming.adminField`), `adminAuth` authorization, and
  `excludeFields`.
- This makes `<single>Items` and `By<Index>` fields appear automatically for any
  admin read model that declares a sub-id / `@index`.
- Keep existing single-key admin RMs (`Plugins`, `PlatformEventGraph`) byte-stable in
  their generated SDL (no sub-id/index → same `single` + `list`). Verify no field-name
  drift vs today (the `queryFieldNamesRegistry` alignment must still hold).

### 1.3 AWS — verify resolver lockstep (likely no change)

- `QueryDbResolvers_AppSync` already emits `resolverByIdMultiple` (`<single>Items`,
  [:174]) and `resolversByIndex` (`By<Index>`, [:234]). With 1.2 emitting the matching
  SDL fields, the existing resolvers find their fields — error 1 disappears.
- Confirm admin read models thread `subIdConfig` + `config.indexes` into the builder
  (they do, via the spec). No `Platform.res` resolver change expected.

### 1.4 Local — harmonize admin resolver registration

- `reventless-local/Platform.res` hand-registers admin query resolvers per
  `queryEntries` index (`[0]`/`[1]`/`[2]`). Replace the positional wiring with a
  generic loop over the admin read models that registers the **same** field set the
  generator emits: `list` (scan + filter/sort), `single` (get by id), `Items` (load
  by partition id via `loadStream`), `By<Index>` (filtered scan over the store).
- Reuse the in-memory store registered under each spec name (no new stores).

### 1.5 Verify Part 1

- `Plugins` / `PlatformEventGraph` queries unchanged (regression check).
- A composite-key admin read model now exposes a working `<single>Items` query
  (proven by Part 2's `PluginHistory`, or a focused fixture).
- Builds green (core/aws/local), zero warnings; core + local suites green.
- Commit: `feat(admin): generate admin read-model query SDL from spec (parity)`.

---

## Part 2 — Finish PluginHistory visibility on the closed gap

The visibility config is **already committed** (`8a1d86ee3`): `PluginHistoryReadModelSpec`
is Public with a composite `subIdConfig`; `PluginHistoryProjection` uses
`UpdateMultiState`; `PluginBaseFragment` has the `PluginHistory` entry;
`Platform_Admin_Structure` has the `pluginHistoryReadModel` queryableDef; AWS uses
`Single_Stream`. Part 1 is what makes that config *valid* (the admin SDL now declares
`<single>Items`). So Part 2 is mostly verification + cleanup, not re-adding.

### 2.1 Spec + projection — keep the composite key (already in place)

- Confirm `PluginHistoryReadModelSpec` stays composite (`subIdConfig` partition
  `name`, sort `transitionKey`) and `PluginHistoryProjection` keeps `UpdateMultiState`.
  No flat-key redesign. No change expected.

### 2.2 Exposure — ensure the generic path covers it

- Part 1 replaces the hand-rolled admin SDL with generation from the spec. **Verify
  PluginHistory is included** in whatever list/iteration Part 1 generates from (today
  it's `PluginBaseFragment.queryEntries`), so it gets `single` + `list` +
  `<single>Items` automatically — and that its admin field names / `queryFieldNamesRegistry`
  entry still line up with `Platform_Admin_Structure`.
- Local: covered generically by Part 1.4 (no per-view hand-wiring).

### 2.3 AWS cleanup + redeploy

- The composite key is unchanged from the failed deploy, so the table is **not**
  replaced — but clear the failed-deploy residue first: delete the orphaned
  EventSourceMapping `be58fe31` (and confirm the `PluginHistory-…` table/stream are
  consistent) so Pulumi reconciles cleanly. See
  [clearing-aws-eventlog-querydb-tables.md](../analysis/clearing-aws-eventlog-querydb-tables.md).
- After redeploy: `Platform_PluginHistory` (list) + `Platform_PluginHistoryEntryItems`
  (per-plugin) resolve; the AutoUI renders the timeline; rows populate via the
  dispatch-fixed projection.

### 2.4 Tests + verification

- Keep the 8 `PluginHistoryProjection_GWT` tests (composite fold unchanged).
- Runtime-verify locally (Platform_PluginHistory list + per-plugin items) and on
  deploy.
- Commit: `feat(admin): expose PluginHistory timeline (composite key, standard surface)`.

### 2.5 (Part 2b, optional) GSIs for dashboards — separate backlog plan

Detailed in **[Backlog/plugin-history-indices-and-dashboards.md](Backlog/plugin-history-indices-and-dashboards.md)**:
`byTransition` / `byDay` (and optional `byActor` / `byVersion`) GSIs, a
version-lifecycle **summary projection** for SLA/rollback metrics, and counters —
mapped to the §6.2.4 opportunity catalogue (status dashboards, deployment/SLA
metrics, rollback intelligence, drift detection, audit). Each `@index` yields a
`By<Index>` query field for free (Part 1). Added incrementally, one per concrete
dashboard.

---

## Part 3 — Full harmonization (separate backlog plan)

Out of scope here; tracked in its own plan:
**[Backlog/admin-readmodel-full-harmonization.md](Backlog/admin-readmodel-full-harmonization.md)**.
It covers (all depending on Part 1 above):

- **3.1** Retire `Platform_UIFragments_Lambda` — serve `UIFragmentRegistry` through
  the standard path. Cross-repo caveat: flat `[X!]!` → `Connection` breaks the
  host-shell consumer; needs a coordinated `reventless-ui` rollout.
- **3.2** Derive `allowedStates` from `@allowedStates` instead of hand-writing it in
  `Platform_Admin_Structure`.
- **3.3** Route admin read models entirely through the ordinary component pipeline
  (the maximal version of Part 1; subsumes 3.1's SDL half).

---

## Sequencing & commits

1. ~~Step 0~~ — **skipped** (no interim deploy).
2. **Part 1** — `feat(admin): generate admin read-model query SDL from spec (parity)`.
3. **Part 2** — `feat(admin): expose PluginHistory timeline (composite key, standard surface)`
   (small — verification + any naming fixups) + AWS cleanup (delete `be58fe31`).
4. **Deploy once** after Part 2 → green.
5. **Part 2b / Part 3** — as needed / backlog.

Each step: full build (zero warnings) + `pnpm test` green before committing. Show
the commit message and get approval; do not push (pushing triggers CI deploy). The
branch deploy stays red between now and Part 2 landing — expected.

---

## Open questions / decisions

1. **Part 1 scope:** minimal (emit `<single>Items` + `By<Index>` for admin
   fragments) vs full harmonization (route admin RMs through the ordinary pipeline).
   This plan assumes **minimal**; full is Part 3.
2. ~~**Do Step 0 now?**~~ **Resolved: skip** — deploying once after Part 1+2, so no
   interim revert. Branch stays red until Part 2 lands.
3. **Retention/TTL** for PluginHistory rows (unbounded growth) — defer; revisit with
   Part 2b.
4. **Default AutoUI view** — global feed vs per-plugin timeline (drives which index,
   if any, is primary).
