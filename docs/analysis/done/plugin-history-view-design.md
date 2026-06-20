# Plugin History View — Storage, Visibility & the Admin Read-Model Parity Gap

> **⚠️ Superseded / historical (2026-06-20).** The `PluginHistory` view this document
> designs was removed from OSS core (commit `0de749a7b`) and re-homed to the
> commercial `@reventlesslab/platform-inspector` as a normal `StateViewSlice`. That
> dissolves the central problem here: a StateViewSlice gets composite keys, GSIs, and
> the full `single`/`list`/`<single>Items`/`By<Index>` surface automatically, so the
> "admin read-model parity gap" framing (§3) and the resulting option matrix (§4–§7)
> **do not apply** to the business view — it already is the recommended end state
> (composite key + GSIs) by construction. Treat the sections below as a record of how
> the decision was reached, not as live guidance.
>
> What remains live and core:
> - **The parity gap itself (§3)** is a genuine OSS framework concern — it still
>   affects the remaining `Plugins` admin read model — and is tracked in
>   [plugin-history-parity-gap.md](../../plans/plugin-history-parity-gap.md) (Part 1, done).
> - **The forward-looking GSI/dashboard design (option D)** now lives in the business
>   repo as `plugin-history-indices-and-dashboards.md`.
>
> Nothing here should be moved to business: the parity-gap premise is OSS-specific and
> doesn't transfer to the slice architecture.

**Status:** Superseded — historical analysis (no code changed by this document)
**Date:** 2026-06-18
**Author:** Martin Lorenz (with Claude)
**Related:** [plugin-lifecycle-redesign.md](../plugin-lifecycle-redesign.md) (§6.2 — the
`PluginHistory` view), [plugin-aggregate-readmodel-vs-normal-harmonization.md](../plugin-aggregate-readmodel-vs-normal-harmonization.md)
(the admin-vs-normal divergence this builds on), [done/plugin-lifecycle-redesign.md](../../plans/done/plugin-lifecycle-redesign.md),
[clearing-aws-eventlog-querydb-tables.md](../clearing-aws-eventlog-querydb-tables.md).

**Scope:** how the `PluginHistory` admin read model (the per-version plugin
lifecycle timeline) should be **stored** and **exposed**. Triggered by a deploy
failure when the timeline was first made visible. The investigation traced the
failure to a **framework parity gap** — admin read models don't get the same
auto-generated GraphQL surface as ordinary read models — and the central
recommendation is: **close that gap first, then design `PluginHistory` on top of
it. No custom admin Lambdas.**

---

## 1. Context

The plugin-lifecycle redesign added two read views folded from the name-keyed
Plugin aggregate's event stream:

- **`Plugins`** — the *current* view, one row per plugin **name** (single-key).
  Kills the duplicate-menu bug. Live and correct.
- **`PluginHistory`** — the *audit* view: one row per lifecycle **transition**
  (`Detected` / `Connected` / `Superseded` / `Promoted` / `Disconnected` /
  `Activated` / `Deactivated` / `Retired` / `IncompatibleDetected`).

`PluginHistory` shipped first as **`Internal`** (no GraphQL resolver). Making it a
Public, **composite-key**, auto-resolver-backed admin read model **failed to
deploy**. The failure is a symptom; the disease is the parity gap (§3).

---

## 2. What happened — the deploy failures

1. **AppSync resolver attaches to a non-existent field**

   ```
   pulumi-nodejs:dynamic:Resource (Platform_PluginHistoryEntryItems):
     error: No field named Platform_PluginHistoryEntryItems found on type Query
   ```

2. **DynamoDB EventSourceMapping 409 conflict**

   ```
   aws:lambda:EventSourceMapping (Platform_PluginHistoryStream2DomainEventsApiStateTopic):
     ResourceConflictException: … mapping already exists … UUID be58fe31-…
   ```

**Error 1** is the parity gap surfacing: the shared resolver layer generated a
`<single>Items` resolver for the composite key, but the **admin** SDL never
declared that field. **Error 2** is incidental — swapping `NoResolver_Stream →
Single_Stream` on an already-stream-enabled table makes Pulumi create a duplicate
StateTopic mapping; it disappears once the read model's resource graph is stable.
The dispatch fix (`fix(aws): run all runtime handlers sharing one source stream`)
is unrelated and stays regardless.

---

## 3. The root: the admin read-model SDL ⇄ resolver parity gap

### 3.1 Two SDL-generation paths

Ordinary (user-plugin) read models and admin read models reach GraphQL by
**different** routes:

- **Ordinary read models** → `GraphQL_FragmentGenerator` generates the query SDL
  **from the spec schema** (keys, sub-ids, indexes, filterable/sortable fields).
- **Admin read models** (`Plugins`, `PlatformEventGraph`, `UIFragmentRegistry`,
  `PluginHistory`) → a **hand-rolled** fragment in
  [`PluginBaseFragment.queryEntries`](../../../reventless/reventless-core/src/plugin/api/PluginBaseFragment.res)
  → `AdminApi.baseFragment`, which emits **only** the `single` + `list` fields.

Both then share the **same** resolver layer (`QueryDbResolvers_{AppSync,GraphQL}`).
This divergence is already documented in
[plugin-aggregate-readmodel-vs-normal-harmonization.md](../plugin-aggregate-readmodel-vs-normal-harmonization.md)
(§1: "The Plugin read model's GraphQL surface is hand-rolled rather than generated
from the spec"). The present document quantifies the *functional* cost of that
divergence and makes closing it a prerequisite.

### 3.2 What the generic generator emits that the hand-rolled admin path does not

`GraphQL_FragmentGenerator` (the ordinary path) already produces, **in lockstep
with the resolver layer**:

| Field | Generator | Resolver | Admin (hand-rolled) |
|---|---|---|---|
| `single` (get by id) | ✅ | ✅ | ✅ |
| `list` (Connection + **filter/sort**) | ✅ | ✅ | ✅ |
| `<single>Items(id, filter, …): Connection!` (sub-id list under one partition) | ✅ `deriveItemsQueryField` ([L298](../../../reventless/reventless-core/src/components/Api/GraphQL_FragmentGenerator.res#L298)) | ✅ `resolverByIdMultiple` ([QueryDbResolvers_AppSync L174](../../../reventless/reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res#L174)) | ❌ |
| `…By<Index>` (per `@index` GSI) | ✅ (`spec.indexes`, [L220](../../../reventless/reventless-core/src/components/Api/GraphQL_FragmentGenerator.res#L220)) | ✅ `resolversByIndex` ([QueryDbResolvers_AppSync L234](../../../reventless/reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res#L234)) | ❌ |

So an ordinary read model can use composite keys **and** GSIs **and** filter/sort
through the standard auto-generated surface. An admin read model gets only the two
basic fields — anything richer makes the resolver emit a field the admin SDL never
declared → the exact "No field named …" failure (error 1), and the same failure
would recur the moment a `@index` is added.

> Note: the standard **`list`** field already carries server-side **filter + sort**
> (derived via `deriveServerCapability` → `filterFields` / `sortFields`,
> [QueryDbResolvers_AppSync L195](../../../reventless/reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res#L195);
> see [autoui-list-ordering-and-filtering.md](../autoui-list-ordering-and-filtering.md)).
> Even a *single-key* admin read model can be filtered by `name`/`transition` and
> ordered by `transitionAt` today — no GSI, no sub-id, no Lambda.

### 3.3 Why custom admin Lambdas are the wrong answer (and the existing one is debt)

The instinct to serve a tricky admin read model with a bespoke Lambda is the
pattern behind `Platform_UIFragments_Lambda`. But inspection shows that Lambda
exists for an **SDL-shape** reason, not a capability gap: `UIFragmentRegistry` is
single-key, and the Lambda just `Scan`s and returns a flat `[X!]!` array instead
of the standard `Connection`. It is **not** evidence that composite keys or
indices *require* a Lambda — it's a divergence that fragments schema generation,
duplicates resolver logic, and bypasses AutoUI.

**Decision: no custom admin Lambdas.** Every admin read model should be designable
with the same primitives ordinary read models use — the two keys (id + sub-id),
information composed into those keys, and `@index` GSIs — through the standard
auto-generated path. The `UIFragments` Lambda is tech debt to **retire** by closing
the gap, not a template to copy.

### 3.4 What "closing the parity gap" entails

Route admin read models through the **same** machinery ordinary read models use, so
their SDL is generated from the spec (and stays in lockstep with the resolver):

- **Core (deploy-time SDL):** generate the admin read-model query fragment via
  `GraphQL_FragmentGenerator` from each spec (honouring `subIdConfig` and
  `config.indexes`), replacing the hand-maintained `PluginBaseFragment.queryEntries`
  / `AdminApi.baseFragment` field list. This emits `<single>Items` and `By<Index>`
  fields automatically.
- **AWS:** no resolver change needed — `QueryDbResolvers_AppSync` already emits the
  matching resolvers; they will simply now find their SDL fields. Retire
  `Platform_UIFragments_Lambda` (serve `UIFragments` through the standard path).
- **Local:** the local platform **hand-registers** admin query resolvers per
  `queryEntries` index (`Platform.res` `queryResolvers->Dict.set(entry[0/1/2]…)`).
  Harmonize this to iterate the generated structure and register the same field set
  (single / list / `Items` / `By<Index>`) generically, instead of positional
  hand-wiring.
- **Scope/risk:** a framework change across `reventless-core` (fragment assembly),
  `reventless-aws` (drop the UIFragments Lambda + SDL wiring), and `reventless-local`
  (generic admin resolver registration). Deploy-path verified. It is larger than
  `PluginHistory` alone — but it is **paid once** and unblocks every admin read
  model (and deletes a Lambda).

### 3.5 Why this must come first

If we instead work around the gap for `PluginHistory` (flat key, or a Lambda), we
(a) entrench the divergence, (b) cannot use composite keys / GSIs on the audit view
without re-hitting the wall, and (c) keep the `UIFragments` Lambda. Closing the gap
first means `PluginHistory` — and any future admin timeline — is designed with the
full, normal toolkit. **This is the plan's step 1; the `PluginHistory` redesign is
step 2, built on it.**

---

## 4. Design options for PluginHistory (given the gap)

### A. Flat single-key list (works **without** closing the gap)

Unique id `name#version#time#kind`, `Set(id, row)`, single-key + standard
`Single_Stream`. Deploys today, renders in AutoUI, and (per §3.2) is filterable by
`name`/`transition` and sortable by `transitionAt` via the standard `list` field.

- **Pros:** no framework work; certain AutoUI rendering; built-in filter/sort
  already covers the main views.
- **Cons:** no DB-efficient per-plugin query (scan + filter); unbounded growth →
  wants TTL; **destructive table replacement** + AWS cleanup; can't add a base sort
  key or GSIs **until the gap is closed**; GWT rework.
- **Role:** the **fallback** if we decide *not* to close the gap, or an interim.

### B. Composite key + custom admin Lambda — **REJECTED**

Keep the composite key and serve it via a bespoke scan Lambda (the `UIFragments`
pattern). **Rejected** per §3.3 (no custom admin Lambdas): it sidesteps the
framework instead of fixing it, doesn't render in AutoUI automatically, and adds to
the very debt we want to remove.

### C. Close the parity gap, then composite key on the standard path — **target**

After step 1 (§3.4), `PluginHistory` keeps its **composite key** (partition `name`,
sort `transitionKey`) and is exposed through the standard auto-generated surface:
`single` + `list` (filter/sort) + `<single>Items` (per-plugin timeline). Visible in
AutoUI, no Lambda.

- **Pros:** efficient per-plugin timeline (`<single>Items` / partition query);
  full standard surface; no flat-key replacement churn; consistent with ordinary
  read models.
- **Cons:** depends on step 1 landing first.
- **Role:** the **recommended end state** for the view itself.

### D. Index design (GSIs) — enabled once the gap is closed

With the gap closed, `@index` GSIs become usable on admin read models: e.g.
`@index` on `transition` (by-state), on `transitionAt` (by-time / SLA windows),
optionally on `name` if a flat base key is chosen instead of composite. Each
generates a `By<Index>` query field automatically.

- **Pros:** unlocks the indexed-query opportunity set (dashboards, drift reports)
  without scans or Lambdas; pure key/annotation design — exactly the toolkit you
  want.
- **Cons:** GSI cost/write-amplification; add only the indexes a real view needs.
- **Role:** **opportunity layer**, added incrementally on top of C.

### E. Revert to Internal (baseline)

`NoResolver_Stream` + `Internal`. Table populated (after the dispatch fix) but not
surfaced. Guaranteed-green deploy; the instant unblock if needed before step 1.

---

## 5. Opportunities — two classes (important distinction)

A rich plugin history (analysis §6.2.4) unlocks: audit & compliance, migration
automation, version diffing & breaking-change detection, rollback intelligence,
deployment/SLA metrics, incident debugging, drift/zombie detection. These split by
**what serves them**:

- **Stream-driven (already enabled, independent of all of the above).** Reacting to
  `VersionSuperseded(from, to)` / `VersionConnected` / `VersionRetired` is served by
  the **`PluginAggrEventLog` event stream**. **Migration automation**
  (`VersionSuperseded` carries *both* plugin definitions for diffing),
  **breaking-change detection**, and **rollback alerting** are a future
  automation-slice reactor on the stream — *no read-model shape gates them.*
- **Read-model-driven (gated by the gap + key/index design).** The admin **audit
  UI**, per-plugin **drill-down**, **status dashboards**, **SLA / deployment-
  frequency** charts, **drift/zombie** reports — all query the accumulated history;
  their efficiency depends on the parity gap being closed (so composite keys /
  indices are usable) and on the chosen keys/GSIs.

Implication: closing the parity gap is what converts the read-model-driven
opportunities from "scan-only / impossible" into "first-class indexed queries"; the
high-value automation opportunities are unblocked separately on the stream.

---

## 6. Comparison matrix

| Criterion | A · Flat (no gap fix) | B · Custom Lambda | **C · Close gap + composite** | D · + GSIs (on C) | E · Internal |
|---|---|---|---|---|---|
| Custom Lambda? | ✅ none | ❌ **rejected** | ✅ none | ✅ none | ✅ none |
| Deploys cleanly | ✅ (after table replace) | ✅ | ✅ (after step 1) | ✅ | ✅ |
| Framework work | none | none | **yes (step 1)** | small (annotations) | none |
| Renders in AutoUI | ✅ certain | ⚠️ bespoke | ✅ certain | ✅ | ❌ |
| Per-plugin query | ❌ scan+filter | ✅ | ✅ `<single>Items` | ✅ | n/a |
| Indexed queries (by-state/time) | ❌ (blocked by gap) | ⚠️ in-Lambda | ⚠️ needs D | ✅ `By<Index>` | ❌ |
| Built-in list filter/sort | ✅ | ❌ (bypassed) | ✅ | ✅ | ❌ |
| Removes existing debt (UIFragments Lambda) | ❌ | ❌ adds debt | ✅ | ✅ | ❌ |
| Opportunity ceiling | medium | medium | high | highest | low |
| Migration automation / diffing | ✅ (stream) | ✅ (stream) | ✅ (stream) | ✅ (stream) | ✅ (stream) |

---

## 7. Recommendation — a two-step plan

**Step 1 (framework, prerequisite): close the admin read-model parity gap.**
Generate admin read-model query SDL from the spec via `GraphQL_FragmentGenerator`
(honouring sub-ids + `@index`), in lockstep with the shared resolver layer;
harmonize the local admin resolver registration to the same generated field set;
retire `Platform_UIFragments_Lambda`. Outcome: admin read models gain composite
keys, `<single>Items`, GSIs, and filter/sort through the standard path — **no custom
Lambdas anywhere** (and one deleted).

**Step 2 (the view): redesign `PluginHistory` on the closed gap (option C, + D as
needed).** Keep the composite key (partition `name`, sort `transitionKey`) for an
efficient per-plugin timeline; expose via the standard auto surface (`list` with
filter/sort + `<single>Items`); add `@index` GSIs only for the specific dashboards
that need them (D). Visible in AutoUI, no Lambda, no flat-key replacement.

**Fallbacks:** if step 1 is deferred, **A (flat single-key)** is the only
no-Lambda way to make the view visible meanwhile (accepting scan-based reads and a
table replacement); **E (Internal)** is the instant unblock. Both are interim — the
target remains C+D on the closed gap.

This sequencing is deliberate: the gap is the actual blocker, fixing it is paid
once and benefits all admin read models, and only on that foundation is the
`PluginHistory` storage/index design free to use the full normal toolkit.

---

## 8. Open questions

1. **Scope of step 1.** Minimal (just emit `<single>Items` + `By<Index>` for admin
   fragments) vs. full harmonization (route admin read models entirely through the
   ordinary component pipeline, per
   [plugin-aggregate-readmodel-vs-normal-harmonization.md](../plugin-aggregate-readmodel-vs-normal-harmonization.md))?
   The latter also subsumes the hand-written `allowedStates` divergence.
2. **Retention / TTL.** Every transition is permanent; do we cap (last K per name /
   N days) or keep a full immutable trail for compliance?
3. **Default UI view.** Global chronological feed vs per-plugin timeline as the
   AutoUI default (drives which index is primary).
4. **Migration automation** — the highest-value *stream-driven* opportunity, and
   independent of this view. Worth its own analysis if pursued.
