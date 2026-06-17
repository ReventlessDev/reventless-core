# Plugin Lifecycle Redesign

**Status:** Analysis / proposal (no code changed by this document)
**Date:** 2026-06-17
**Author:** Martin Lorenz (with Claude)

**Scope:** how a plugin's lifecycle (connect / heartbeat / supersede / disconnect
/ retire) should be modelled and owned; where "which version is current" is
decided; whether multiple versions may run at once; and what a version deploy
does to infrastructure (incl. zero-downtime). Motivated by the duplicate-menu bug
but broader than it.

## 1. Problem statement

The deployed hybrid platform shows **duplicate navigation menu entries** — each
plugin's read models appear once per still-`Connected` version (Catalog ×4,
Ordering ×3). The visible symptom was mitigated by deduping in the manifest
queries (commit `7a21ca304`), but that is a read-side band-aid over a write-side
design problem.

Two structural issues drive the duplicates and motivate this redesign:

1. **Plugin lifecycle "supersede the older version" is decided outside the
   write model.** The decision is taken at *deploy time* by a hook that **reads
   the `Plugins` read-model table directly** (a DynamoDB `Scan`) and then
   publishes `Retire` commands. Reading a projection to drive a command is
   backwards (CQRS-wise) and couples deployment correctness to projection
   freshness, to a cross-stack export, and to the deployment topology.
2. **The `Plugins` read model holds one row per `name@version`.** Because the
   Plugin aggregate is keyed by `name@version`, the projection writes one row
   per version. "Only one version should be current" is an invariant that is
   *assumed* everywhere (the manifest collapses `name@version` → bare name) but
   *enforced nowhere*.

**Design goals (from the requirement):**

- **No read-model-table read may *drive a command or lifecycle decision*.**
  Reading a view for display or routing is fine; *scanning the RM at deploy time
  to publish `Retire`* is not.
- The "current" Plugin view must **always contain only the newest connected
  version per plugin name**. This alone removes the duplicate-menu problem at the
  source.
- Evaluate splitting into **two** projections:
  - a **current** view (`Plugins`) — one row per plugin name, newest connected
    version only;
  - a **history** view (`PluginHistory`) — the audit trail of every version's
    connect / disconnect / retire / supersede transitions.

## 2. Current architecture (as-is)

### 2.1 The aggregate is per **version**

- `Plugin.makeId(name, version) = "${name}@${version}"`
  — [Plugin.res:51](../../reventless/reventless-core/src/components/Plugin/Plugin.res#L51)
- The Plugin aggregate instance id is that `name@version`
  — [Plugin_Builder.res:127](../../reventless/reventless-core/src/components/Plugin/Plugin_Builder.res#L127)
- The heartbeat Lambda's `PLUGIN_ID` env var is the same `name@version`
  — [PluginRuntime_Builder.res:714-717](../../reventless/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res#L714)

**Consequence:** every version of a plugin is a *separate aggregate instance*
with its own event stream and its own lifecycle. No instance has any knowledge
of the other versions. There is no write-side owner of the question *"which
version of plugin X is current?"*.

### 2.2 State machine ([PluginBehavior.res](../../reventless/reventless-core/src/admin/PluginBehavior.res))

States: `NotConnected → Detected → Connected ⇄ Disconnected`, plus `Inactive`
(admin suspend) and `Retired` (deploy supersession). Liveness is **heartbeat
driven**:

- `NotConnected + Heartbeat → UnknownPluginDetected` (→ `Detected`)
- `Detected + Connect(def) → Connected`
- `Connected + Heartbeat → []` (keep-alive no-op)
- `Disconnected + Heartbeat → Reconnected`
- `Retired + Heartbeat → Reconnected` ← revives a superseded version
  ([lines 124-134](../../reventless/reventless-core/src/admin/PluginBehavior.res#L124))

There is **no deploy-time `Connect`**. A plugin comes up purely via the
heartbeat handshake: heartbeat → `UnknownPluginDetected` →
`PluginConnectExtension` publishes `ConnectPlugin` → `Connect`
([PluginExtensionPoint_Plugin.res:138-169](../../reventless/reventless-core/src/admin/PluginExtensionPoint_Plugin.res#L138)).
Each heartbeat also (re)creates a per-version timeout that fires `Disconnect`
when heartbeats stop ([line 143](../../reventless/reventless-core/src/admin/PluginExtensionPoint_Plugin.res#L143)).

### 2.3 The projection is per **version**

`PluginsProjection` keys rows by the aggregate id (`name@version`):
`Set(id, state)` / `UpdateWithDefault(id, …)`
— [PluginsProjection.res:61](../../reventless/reventless-core/src/admin/PluginsProjection.res#L61).
The read model spec is `Plugins`
([PluginsReadModelSpec.res:1](../../reventless/reventless-core/src/admin/PluginsReadModelSpec.res#L1)),
with `status ∈ {Connected, Disconnected, Inactive, Retired}`.

### 2.4 Supersession is decided at deploy time by reading the read model

`publishRetireForOlderPluginVersions`
([Platform.res:577-664](../../reventless/reventless-aws/src/Platform.res#L577)):

1. `ScanCommand` the `Plugins` RM table, filter `name = :n AND status =
   "Connected"` ([lines 585-595](../../reventless/reventless-aws/src/Platform.res#L585)).
2. Keep rows whose `version != <deploying version>` ([line 602](../../reventless/reventless-aws/src/Platform.res#L602)).
3. Publish a `Retire` command to the Plugin aggregate command topic for each.

The RM table name and command-topic URL are sourced from the **platform stack's
exports** via `StackReference` ([lines 833-844](../../reventless/reventless-aws/src/Platform.res#L833)).

### 2.5 The manifest consumes the read model and assumes single-version

`Platform_ComponentDefinitions` and `Platform_UIFragments` scan the RM, filter
`status = Connected`, and collapse `name@version` → bare name. They now also
dedup to the highest version (commit `7a21ca304`) — but that is compensating for
the RM legitimately containing several `Connected` rows per name.

### 2.6 What a version deploy *physically* does (infrastructure)

This is the crux for §§11–12 below, and it is easy to get wrong: **a plugin
deploys as a single Pulumi stack, and that stack's resources are named by plugin
*name*, not `name@version`.**

- A plugin's AWS stack (`catalog-aws`, `ordering-aws`) calls
  `Platform.deployPlugin(~plugin=module(Catalog))`. The **version is the plugin
  package's own version** at build time (`PackageVersion`), not a deploy
  argument.
- Inside `Plugin_Builder`, every infrastructure resource is named from
  `childName = name->ComponentType.name(...)` — the plugin **name, with no
  version** ([Plugin_Builder.res:129](../../reventless/reventless-core/src/components/Plugin/Plugin_Builder.res#L129),
  used at :149/:578/:735). The EventCollector Lambda, command-handler Lambdas,
  QueryDb/EventLog DynamoDB tables, AppSync resolvers, heartbeat Lambda +
  CloudWatch rule — all name-keyed.
- The **version appears only as a logical label**: the Plugin aggregate instance
  id (`Plugin.makeId(name, version)` → `name@version`), the heartbeat Lambda's
  `PLUGIN_ID` env var, and the deploy-time schema-fragment rows.

**Consequences:**

1. **There is exactly one set of running infrastructure per plugin name, updated
   in place.** Deploying v2 to `catalog-aws` does *not* stand up a second set of
   Lambdas/tables — Pulumi reconciles the existing resources to v2 (new Lambda
   code, env, schema). v1's code is *replaced*, not run alongside.
2. **Domain data persists across versions.** The EventLog/QueryDb tables are
   name-keyed, so v2 inherits v1's data. (This is why version transitions don't
   lose data — and why two versions can't trivially run with *divergent* table
   schemas: there is one table.)
3. **The only thing that "two versions" means today is two lifecycle rows.** The
   Plugin aggregate keys by `name@version`, so v1's and v2's *bookkeeping* rows
   coexist in the admin store even though only one set of infra is live. The
   duplicate-menu bug is therefore a **lifecycle-bookkeeping artifact**, not two
   running plugins.
4. **The version handover is heartbeat-driven, not deploy-driven.** After v2's
   code is live, v2 only becomes `Connected` on its **first heartbeat tick**
   (PLUGIN_ID now = v2); v1's row stops getting heartbeats and `Disconnected`s on
   its timeout. So there is a built-in *overlap window* (both rows `Connected`)
   and a *handover lag* (until v2's first heartbeat). See §12.

## 3. Why the current design produces the bug

| Cause | Effect |
|---|---|
| Aggregate keyed by `name@version` | No write-side owner of "current version per name" |
| Supersession decided at deploy time, reading the RM | Couples to projection freshness, cross-stack export, and deploy topology; silently no-ops if any of those is missing (e.g. export absent, monolithic mode, pre-fix data) |
| RM holds one row per version | Several `Connected` rows per name → duplicate manifest entries |
| `Retired + Heartbeat → Reconnected` | A stray/late heartbeat from a superseded version un-retires it |

The committed query-side dedup (`7a21ca304`) masks rows 3–4. This document
removes the *causes*: row 2 (delete the deploy-time RM scan) and row 3 (a
name-keyed "current" projection), which together also neutralise row 4. Row 1
(per-version aggregate) is **kept** under the recommended option — it is not the
bug itself, only the reason "current version" had no owner.

## 4. The key realisation

> The current Plugin view should *always* contain only the newest connected
> version per plugin name.

If that property holds — whether **computed in a projection** (newest-connected
wins) or **enforced as a write-side invariant** — then:

- the manifest reads exactly one row per plugin name → **no duplicates,
  structurally**;
- the read-side dedup becomes redundant (kept only as defence in depth);
- the deploy-time RM scan disappears — "current" follows from a newer version
  *connecting*, with no command driven by reading a read model.

The architectural question is therefore **where the supersession decision lives**,
along a spectrum:

- **read-side, inferred** — a plugin *version* is the entity; "current" is a
  projection (Option A);
- **write-side via a name-level reactor** — versions stay their own entities, but
  a separate component *decides and records* supersession (Option A′);
- **write-side in one aggregate** — the plugin *name* is the entity and owns the
  whole lifecycle (Option B).

All three deliver "one current row per name"; they differ on whether supersession
is a recorded event and on whether "one current" is an enforced invariant or an
eventually-consistent intent/view.

## 5. Options

All options below **delete the deploy-time RM-scan retire hook** and feed a
**name-keyed `Plugins` "current" view** to the manifest — that is the part that
fixes the duplicate-menu bug. They differ in **who owns the supersession
decision** and **how each plugin version is modelled**.

> **Migration cost is explicitly *not* a deciding factor** (per requirement): an
> alpha event-store wipe is acceptable. The choice is therefore architectural —
> write-side richness, modelling fidelity, invariant strength, and rework — not
> logistics. §8 records what each entails for completeness.

### Option A — read-model differentiation (per-version aggregate, supersession *inferred*)

Treat **a plugin version as the entity** (as today; aggregate keyed by
`name@version`). Move only "which version is current" to the **read side**: a
`Plugins` projection keyed by `name` folds all versions' events and keeps the
**highest currently-connected** version (`Plugin.compareVersions`; on disconnect,
fall back to the next-highest connected → rollback). It carries a small per-name
`{version → status}` map to compute that.

- **Supersession is *inferred* in the projection** — there is no `Superseded`
  event.
- **Pro:** least rework; robust even if a heartbeat timeout misfires (a stale
  lower version is never the highest connected, so it never surfaces); the
  stray-heartbeat-revival race is harmless for the same reason.
- **Con:** no first-class supersession event → only a *thin*, reconstructed audit
  history and **no clean migration hook** (§6.2.3). This is the **baseline**, and
  the first increment of A′ — not a destination once rich history is wanted.

### Option A′ — per-version aggregates **+ a name-level supersession decider** (recommended)

Option A **plus an explicit write-side owner of supersession.** Keep the
per-version aggregates exactly as they are — each version still owns its
`Connect` / `Heartbeat` / `Disconnect` / `Deactivate` / **manual `Retire`** (this
is already true today). Add **one new admin component keyed by `name`** — a
`PluginRegistry` aggregate or an automation slice — that:

1. consumes the per-version `Connected` / `Disconnected` events,
2. decides the current version (`Plugin.compareVersions`), and
3. **emits intentful lifecycle events**: `VersionConnected`,
   `VersionSuperseded(from, to)`, `VersionPromoted` (rollback).

Both projections (§6) fold *these* events, so the `current` view **and** the rich
`PluginHistory` are faithful, not reconstructed.

- **Pro:** supersession/rollback are **decided and recorded on the write side** —
  delivering the rich, queryable history and the migration-automation hook the
  requirements call for (§6.2) — while **keeping the existing per-version model**
  (no aggregate re-keying, no heartbeat rewiring). It is the **least rework that
  still puts supersession on the write side** (literally Option A + one
  component).
- **Con:** the supersession decider is a **second write-side component**, so
  "current" is decided **eventually-consistently** w.r.t. the per-version events
  it reacts to — a strongly-consistent *intent*, not a single-aggregate invariant.

### Option B — single aggregate keyed by **name** (one owner, enforced invariant)

Treat **the plugin (name) as the entity**; versions become internal state. **One**
aggregate keyed by `name` receives every version's heartbeat/connect and decides
the *entire* lifecycle — connect, supersede, disconnect, retire — **synchronously
in one place**, emitting the same `VersionConnected` / `VersionSuperseded` / …
events. State: `{ current, live: dict<version, {definition, status,
lastHeartbeatAt}> }`; `Heartbeat(V>current)` → connect+supersede, `V==current` →
keep-alive, `V<current` → ignored, timeout on current → recompute highest live.

- **Pro:** **one decider, one stream, one source of truth.** "Exactly one current
  version" is an **enforced invariant** (impossible to violate); the audit history
  is a single linear stream with no cross-component seam.
- **Con:** most rework — re-key the aggregate, **re-route heartbeats** to the
  `name` id (version in payload), and fold all per-version lifecycle logic into the
  one aggregate. Models N independent runtimes as sub-states of one boundary
  (faithful-enough: heartbeats emit no events at `V == current`).

### Option C — admin-level DCB / `PluginRegistry` for cross-*name* invariants

Out of scope for single-name lifecycle (see Appendix A). Relevant only if
cross-*plugin-name* invariants (EP-name uniqueness, dependency sets) become hard
requirements — and even then it is an *admin-store* mechanism, never
business-plugin DCB.

### 5.1 Contrast: A vs A′ vs B

Option C is set aside (different problem — Appendix A). Migration is omitted as a
row (not a deciding factor); rework reflects code change, not data migration.

| Dimension | **Option A** | **Option A′** *(recommended)* | **Option B** |
|---|---|---|---|
| Each version modelled as | own aggregate (`name@version`) | own aggregate (`name@version`) | sub-state of one `name` aggregate |
| Supersession decided | **read-side, inferred** | **write-side — a name-level reactor** | **write-side — the name aggregate** |
| `VersionSuperseded` event | none | **yes** | **yes** |
| Rich audit history / migration hook | thin (reconstructed) | **strong** | **strong** |
| "Exactly one current" | eventual *view* | eventual *intent* (2 components) | **enforced invariant** |
| Consistency model | — | eventual: version events → decider | synchronous in one aggregate |
| Write-side components | per-version aggregates | per-version aggregates **+ 1** | one `name` aggregate |
| Heartbeat routing | unchanged | unchanged | **re-route to `name`** |
| Per-version runtime fidelity | high | high | merged into one boundary |
| Rework | lowest | low (add one component) | highest |

### 5.2 Recommendation

**Option A′.** With migration no longer a cost, the decision is purely how much
lifecycle richness you want and how it is modelled — and A′ is the sweet spot:

- It delivers the **rich, write-side lifecycle** the requirements ask for —
  `VersionSuperseded` / `VersionPromoted` as real events, a faithful
  `PluginHistory`, and a clean migration-automation hook (§6.2.4) — **without**
  re-keying the aggregate or rewiring heartbeats.
- It **keeps the existing per-version model** (each deployed version is its own
  runtime and its own aggregate), making it the **least rework that still puts
  supersession on the write side**. Option A is literally its first increment:
  ship A's name-keyed projection + hook deletion, then add the decider.

**Choose Option B over A′** only if "exactly one current version" must be a
**single-aggregate enforced invariant** rather than a strongly-consistent intent
across two components — i.e. you want one linear lifecycle stream and accept the
larger rework (re-key + heartbeat rerouting). Now that migration is moot, B is a
legitimate close second; the real question reduces to **"per-version aggregates +
a supersession reactor (A′)"** vs **"one unified `name` aggregate (B)"**. A′ wins
on rework and runtime fidelity; B wins on a single linear audit stream and a hard
single-current invariant.

**Option A** stays only as the minimal duplicate-menu fix / first increment of
A′ — not a destination, since its thin inferred history is exactly what the
rich-history requirement rules out. **Option C** is reserved for a future
cross-*name* invariant (Appendix A).

Actionable steps: §8. Bug-level recap: §7.

## 6. Read-model / state-view design (two projections)

Both projections consume the Plugin lifecycle events. Under **Option A** those
are the *existing* per-version events (`Connected` / `Reconnected` /
`Disconnected` / `Deactivated` / manual `Retire`, each carrying its `name@version`
and `pluginDefinition`) — no new event types, but supersession is inferred
(§6.2.3). Under **Option A′ / B** there is additionally an explicit
`VersionSuperseded` (and `VersionPromoted`) event — emitted by the name-level
decider (A′) or the name aggregate (B) — which is what makes the rich history in
§6.2 faithful rather than reconstructed.

### 6.1 `Plugins` — current view (one row per name) — **the direct fix**

- **Key:** plugin **name** (no version) — the new projection Option A adds.
- **Content:** the currently-connected version's `definition`, `structure`,
  `uiFragments`, `apiSchemaFragment`, plus `version` and `status`.
- **Fold (Option A):** maintain a small per-name `{version → status}` map.
  `Connected/Reconnected(name@V)` → mark V connected; if `compareVersions(V,
  current) >= 0`, write V's data into the row. `Disconnected/Deactivated(name@V)`
  → mark V not-connected; if V *was* the current, recompute the highest
  still-connected version and rewrite the row (rollback), else leave the row.
- **Manifest + runtime routing read this** → exactly one entry per plugin →
  duplicates impossible and routing unambiguous. The query-side dedup
  (`7a21ca304`) becomes defence-in-depth, no longer load-bearing.

This is the projection whose **"newest connected version only"** property is the
direct fix the requirement calls out.

### 6.2 `PluginHistory` — the rich lifecycle / audit view

#### 6.2.1 A richer lifecycle: automatic vs manual transitions

A faithful history needs the lifecycle to record *why* a version changed state.
The states should separate **automatic** from **manual (admin)** transitions:

| State | Trigger | Kind | Still listed? | Revivable? |
|---|---|---|---|---|
| `Connected` | heartbeat handshake | auto | yes (current if highest) | — |
| `Disconnected` | heartbeat **timed out** | auto | **yes** (shown, unavailable) | yes — reconnects on next heartbeat |
| `Superseded` | a **newer version connected** | auto (deploy) | yes (not current) | yes (rollback) |
| `Inactive` | admin **Deactivate** | manual | yes | admin Activate |
| `Retired` | admin **explicitly retires** it | **manual** | **no** (archived) | no (terminal) |

Two corrections to earlier drafts:

- **`Disconnected` ≠ gone.** A timed-out version stays in the system (listed,
  greyed) — it just isn't reachable, and reconnects if it heartbeats again. It is
  *not* removed.
- **`Retired` is a deliberate admin act, not a deploy artifact.** Today's code
  overloads `Retired` to mean "auto-superseded by a newer version"; that
  automatic concept should be renamed **`Superseded`**, freeing `Retired` for the
  manual "this is really gone — archive it" decision. (An earlier draft suggested
  *dropping* `Retired` — wrong; it should be **kept and promoted** to a
  first-class manual transition.)

This is what makes the lifecycle genuinely rich: an admin reviews the
`Disconnected` / `Superseded` old versions and *chooses* to `Retire` (archive)
them — a manual cleanup step, recorded as an intentful event.

#### 6.2.2 Two consumers, two views

- **AutoUI nav manifest** (§6.1): only the **current `Connected`** version per
  name. `Disconnected` / `Superseded` / `Inactive` / `Retired` never appear in
  navigation — this is the duplicate-menu fix.
- **Admin plugin-lifecycle view** (`PluginHistory`): **all** versions, **all**
  states, plus the transition timeline — where an admin sees what is disconnected
  and decides what to retire.

#### 6.2.3 Which option gives a faithful history

Most of the lifecycle is already write-side in **every** option, because each
version's own aggregate decides and records its own transitions — `Connected`,
`Disconnected` (timeout), `Inactive`/`Activate`, and the **manual `Retire`** are
all per-version events, no inference. So for *per-version* richness, even Option
A is fine.

The **one** transition that is not a per-version decision is **supersession**
("v73 took over from v72") — inherently cross-version — and that is where the
options diverge:

- **Option A** records no `Superseded` event: the current-view projection
  *infers* supersession by watching v73 connect and comparing versions.
  Per-version facts are faithful, but the **supersession relationship** (who
  superseded whom, exactly when) is **reconstructed on the read side** — fragile
  under out-of-order events / flapping, with no first-class record for migration
  logic to hook.
- **Options A′ and B** *decide* supersession on the write side and emit an
  intentful **`VersionSuperseded(from: v72, to: v73, at: T)`** (carrying both
  definitions). History becomes a faithful fold — zero inference — and that event
  is the natural migration trigger (§6.2.4). A′ emits it from the name-level
  decider; B from the name aggregate (see §5 for the full definitions and the A′
  vs B trade).

**Verdict:** a rich, queryable, migration-driving history requires supersession
to be a *decided* event — i.e. **Option A′ (recommended) or B**, not Option A.
You can only faithfully project events you actually decide on the write side.

#### 6.2.4 Opportunities a rich plugin history unlocks

- **Audit & compliance:** an immutable, event-sourced record of who deployed /
  superseded / retired which version and when — every transition explicit.
- **Migration automation:** a `VersionSuperseded(from, to)` event (carrying both
  `pluginDefinition`s) is a deterministic trigger for schema/data migrations
  between versions — "v72→v73 added event field X, run migration M".
- **Version diffing & breaking-change detection:** each version's captured
  `structure` / `apiSchemaFragment` / command-event-readmodel sets enable
  v-to-v diffs → changelogs, CompatMatrix population, breaking-bump detection.
- **Rollback intelligence:** a `VersionSuperseded` quickly followed by a reverse
  promotion → "v73 rolled back after 4 min" → flag a bad release.
- **Deployment / SLA metrics:** per-version connected duration, deploy→first-
  heartbeat lag (§12), supersession frequency, mean version lifetime.
- **Incident debugging:** the dual-connected / handover class of bug becomes
  diagnosable directly from the timeline.
- **Drift / zombie detection:** old versions lingering `Connected`, or
  `Disconnected`-but-never-`Retired`, surface as operational hygiene — exactly
  the failure behind the original bug.

#### 6.2.5 Keying

Partition `name`, sort `version#transitionAt` for the **timeline** (the audit
trail); an optional `name` + `version` **inventory** view sits alongside for
"latest state per version". Never feeds the manifest; internal visibility
(`@@reventless.visibility(Internal)`).

### 6.3 ReadModel vs StateViewSlice

- Under **Options A / A′ / B (aggregate-based)**, both views are **ReadModels** —
  the idiomatic projection for an aggregate, queryable over GraphQL.
- Under **Option C (DCB)**, the equivalents are **StateViewSlices** (the
  DCB-world projection). The two views map cleanly either way.

**Naming:** repo convention is *plural nouns* for read models
(`.claude/rules/app-developer.md`). The current view stays `Plugins`. The
history view should be `PluginHistory` per the request, or `PluginVersions` to
match the plural convention — flagged as an open naming choice (§9).

### 6.4 Visibility

Both are internal/admin views. `PluginHistory` is a candidate for
`@@reventless.visibility(Internal)` (hidden from AutoUI manifest) unless we want
an admin history page.

## 7. How this fixes the reported bug (all options)

The duplicate-menu fix is the part **every** option shares — the name-keyed
current view + deleting the retire hook. (A′/B additionally record supersession;
that is for the history, not the bug.)

- **Duplicates:** the name-keyed `Plugins` view holds exactly one row per plugin
  → the manifest can only ever emit one entry per plugin. The query-side dedup
  (`7a21ca304`) is no longer load-bearing.
- **No RM read drives a command:** the deploy-time retire hook is **deleted**.
  Nothing reads a read model to *decide* a lifecycle transition; the projection
  just folds events, and runtime routing reads the current view (a normal query).
  No `Scan`-to-retire, no stack export, no monolithic-vs-plugin-host divergence.
- **Heartbeat-revival race:** a revived older version is not the highest
  connected version, so the current view ignores it. Rollback works because the
  view falls back to the highest still-connected version when the newer one
  `Disconnected`s via its own timeout.

## 8. Rollout steps

Migration is not a deciding factor (an alpha event-store wipe is acceptable);
these are the *implementation* steps. A → A′ is incremental; B is an alternative
target, not a later step of A′.

**Step 1 — Option A (the duplicate-menu fix).**
- Add the name-keyed `Plugins` **current** projection (§6.1) and (re)shape the
  history/inventory view (§6.2). Rebuild projections by replay.
- **Repoint consumers** — manifest queries and `forwardCommand` routing — from the
  per-version RM to the name-keyed current view.
- **Delete** `publishRetireForOlderPluginVersions` and its plumbing (stack-ref
  reads, the gate, the `pluginAggrCmdTopicUrl` export). Audit whether the
  `pluginRmTableName` export is still needed for the runtime status gate.
- **Rename, don't drop, the lifecycle states** (§6.2.1): the *automatic*
  deploy-supersession concept (today's `Retired`) becomes **`Superseded`**;
  **`Retired` is repurposed for manual admin retirement**; keep `Disconnected`
  (auto timeout) and `Inactive` (admin suspend) distinct.
- Keep the committed manifest dedup (`7a21ca304`) as defence-in-depth.

**Step 2 — Option A′ (recommended target) — additive on top of Step 1.**
- Add the **name-level supersession decider** (`PluginRegistry` aggregate or an
  automation slice keyed by `name`, in the admin) that reacts to per-version
  `Connected` / `Disconnected` events and emits `VersionSuperseded` /
  `VersionPromoted`.
- Point `PluginHistory` and the `current` view at those events — faithful,
  inference-free. No aggregate re-keying, no heartbeat rewiring.

**Alternative — Option B (instead of A′).**
- Re-key the Plugin aggregate `name@version → name`; **wipe** the Plugin EventLog
  + Plugins QueryDb (plugins re-register via heartbeat).
- **Re-route heartbeats** from `name@version` to `name` (`PLUGIN_ID` env + command
  id) in `PluginRuntime_Builder` / `Plugin_Builder`; fold per-version lifecycle
  logic into the one aggregate.
- Pick this over A′ only for the single-aggregate enforced-invariant / single
  linear audit stream (§5.2).

## 9. Open questions

1. **Projection state for "highest connected" (Option A).** The name-keyed
   current view must hold a per-name `{version → status}` map to recompute the
   current version on disconnect. Confirm the ReadModel projection model supports
   carrying that map in the row state (it does — fat projection state keyed by
   name), and that out-of-order events across version streams converge correctly.
2. **Old-version disconnect still depends on the heartbeat timeout.** Option A is
   robust for the *view* even if the timeout misfires (zombies aren't highest),
   but the *inventory* view will show lingering `Connected` rows. Decide whether
   that is acceptable or whether to keep a lightweight cleanup.
3. **History granularity:** inventory (`name`+`version`) vs timeline
   (`name`+`version#time`) — §6.2.
4. **Naming:** `PluginHistory` (matches request) vs `PluginVersions` (plural
   read-model convention)?
5. **Lifecycle-state rename (§6.2.1).** Splitting the overloaded `Retired` into
   auto **`Superseded`** + manual **`Retired`** touches every reader of
   `status` (manifest filters, `forwardCommand`, admin UI,
   `PlatformEventGraphProjection`). Audit them; in particular the manifest must
   show only the **current `Connected`** version while the admin view must show
   `Disconnected` / `Superseded` too (§6.2.2). Confirms the auto/manual split is
   wired end-to-end.
6. **A′ supersession decider — aggregate or automation slice?** The name-level
   decider reacts to per-version events; decide whether it is a `PluginRegistry`
   aggregate (commanded) or an automation slice (event-reactive), and accept its
   eventual consistency w.r.t. the version events.
7. **Manual `Retire` UX & authority.** Where does the admin `Retire` command live
   (per-version aggregate, today), and what gates it (admin authz)? Define the
   archive semantics (`Retired` removed from listings, not auto-revivable).
8. **Cross-name consistency on the horizon?** If EP-name uniqueness / dependency
   sets (Appendix A) become hard requirements, revisit Option C / a
   `PluginRegistry` aggregate.

## 10. TL;DR

- **Decision: Option A′.** Keep the per-version aggregates; add a **name-keyed
  `Plugins` "current" projection**, **delete** the deploy-time RM-scan retire
  hook (that much is Option A, the minimal fix), **and** add a **name-level
  supersession decider** that emits explicit `VersionSuperseded` / `VersionPromoted`
  events — giving a faithful, write-side rich history with the least rework.
  Migration is not a deciding factor. Escalate to full **Option B** (one
  `name` aggregate) only for a single-aggregate *enforced* single-current
  invariant. Contrast: §5.1; reasoning: §5.2; steps: §8.
- **Why it works:** "which version is current" stops being inferred at query time
  from a pile of per-version `Connected` rows and becomes one authoritative row
  per plugin — duplicate menus impossible by construction; supersession is a
  recorded event, not a read-side guess.
- **Lifecycle:** distinguish auto `Disconnected` (heartbeat timeout, still listed)
  from auto `Superseded` (newer version) from manual `Retired` (admin "really
  gone", terminal) — §6.2.1. This richer model is the reason A′/B (supersession as
  a decided event) beats inferring it read-side.
- **Boundaries:** one *active* version per plugin (§11); near-zero-downtime
  handover, remaining gap closeable by a deploy-time heartbeat (§12); cross-*name*
  invariants are out of scope and not a business-plugin DCB problem (Appendix A).

## 11. Should multiple versions of a plugin run at once?

**Short answer: no in steady state — exactly one *active* version per plugin —
but a brief transition overlap is expected and desirable (it is what enables
zero-downtime handover). The redesign should make single-active the steady-state
property, not forbid the transition overlap.**

### 11.1 What's possible today

Per §2.6, **today you cannot run two versions of one plugin simultaneously** even
if you wanted to: one Pulumi stack per plugin, name-keyed resources, in-place
update. v2 *replaces* v1's code. The "multiple connected versions" you see is
bookkeeping (multiple aggregate rows), not multiple runtimes. To genuinely run
two versions you would need either two stacks (`catalog-aws-v1`,
`catalog-aws-v2`) or version-suffixed resources within one stack — neither
exists.

### 11.2 Why event sourcing pushes hard toward single-active

A plugin owns an **EventLog** (its source of truth) and projects QueryDbs from
it. Running two versions concurrently forces one of two bad shapes:

- **Shared EventLog/QueryDb** (today's name-keyed tables): two versions write the
  *same* streams with *different* event/command/state schemas → serialization
  drift, projection corruption, ambiguous command routing. The single-writer
  assumption of an aggregate's EventLog is violated.
- **Separate EventLogs per version:** split-brain — two sources of truth for the
  same domain. Orders written against v1 are invisible to v2 and vice-versa. No
  coherent "current state" exists.

So "two versions of the same plugin, both live, both authoritative" is
fundamentally **at odds with one-source-of-truth**. The natural model is
**supersession** (v2 takes over from v1), not **coexistence**.

### 11.3 Use cases that *look* like multi-version, and how to serve them

| Desired capability | Real need | Reventless-shaped answer |
|---|---|---|
| **Canary / gradual rollout** | route a fraction of traffic to v2 | Hard with one EventLog (writes can't fork). Better served by **schema-compatible evolution** + feature flags inside one version, or platform-level traffic shaping *in front of* an idempotent command API — not two plugin versions. |
| **Backward-compatible API during migration** | old clients keep working while new clients use new fields | This is **schema evolution within one version** (additive events/fields, `@schema` tolerant decoding), not two versions. The CompatMatrix / protocol versioning already targets this. |
| **Blue-green / instant rollback** | switch back to the previous version fast | Supersession with **fast demotion** (see §12.3): keep the previous version's row revivable so a redeploy/rollback flips "current" back. One active at a time, fast switch. |
| **A/B of UI only** | two UIs, same data | A read-only concern — could be served by two *UI fragments* over one data version, not two plugin lifecycles. |

Net: the genuine needs are met by **schema evolution + fast supersession/rollback
+ (optionally) UI-level variation**, none of which require two *active* domain
versions.

### 11.4 Should the framework *prevent* multiple active versions?

**Yes — and the redesign already does, implicitly.** "Current = newest connected
version" (Option A's projection, or Option B's invariant) means at most one
version is ever surfaced as active for routing/manifest. The transition overlap
(v1 still connected while v2 connects) is tolerated and resolves to the newest.
What should be *prevented* is two versions being *independently authoritative* —
which the single name-keyed EventLog already enforces at the data layer.

**Recommendation:** treat single-active-version as an explicit, documented
invariant of the platform. Do **not** invest in multi-active-version
infrastructure unless a concrete need appears that schema-evolution + rollback
cannot serve; if it ever does, it is a much larger design (per-version stacks,
version-aware routing, data strategy) and belongs in its own analysis.

## 12. Can we guarantee zero-downtime plugin updates?

**Near-zero-downtime is achievable and is largely what happens today; a hard
*guarantee* depends on the kind of change. The lifecycle redesign helps by making
the v1→v2 handover continuous at the manifest layer.**

### 12.1 What is and isn't graceful in the current deploy

| Resource | Update behaviour | Downtime risk |
|---|---|---|
| Lambdas (EventCollector, command handlers, heartbeat) | in-place code/env update | **Minimal** — in-flight invocations drain on old, new invocations hit new; only normal cold-start |
| DynamoDB EventLog/QueryDb (name-keyed, persistent) | in-place; **new GSIs backfill async** | **Window** if v2 immediately queries a GSI still backfilling |
| AppSync schema (`preResolversSchemaHook` → `startSchemaCreation` + `waitForSchemaActive`) | schema replace, then resolvers | **Window** during schema propagation; mismatched queries can transiently fail |
| Cross-plugin protocol (extension points) | declared on connect, validated eventually | **Eventual** — `ReportIncompatibility` is detection, "connection still proceeds" |
| Lifecycle/manifest (Plugin aggregate + current view) | v1 stays current until v2's first heartbeat | **No gap** — see 12.2 |

### 12.2 The lifecycle handover is *continuous* (and the redesign keeps it so)

Because v2 becomes `Connected` only on its **first heartbeat** and v1 remains
`Connected` until its **timeout**, there is a natural overlap during which the
"current" view can always serve a working plugin definition:

- **Before v2's first heartbeat:** current = v1 (its code is being replaced, but
  its lifecycle row and manifest entry are intact). The SPA keeps rendering v1's
  UI/schema.
- **After v2 connects:** current flips to v2 (newest connected). v1's row later
  `Disconnected`s on timeout.

So the manifest never shows *nothing*; it transitions v1 → v2. **Option A's
"newest connected wins" projection preserves exactly this** (and the discarded
deploy-time retire hook actually *hurt* it, by trying to yank v1 out before v2
was ready). This is a point in favour of the redesign for zero-downtime, not just
for de-duplication.

### 12.3 What would make it a real guarantee

1. **Heartbeat-interval handover lag.** v2's UI/schema only goes live on its
   first heartbeat. To tighten this, fire an **immediate heartbeat on deploy**
   (one synthetic tick at the end of `deployPlugin`) so v2 connects in seconds,
   not after a full interval. (This is publishing a *heartbeat*, not reading the
   RM to drive a command — consistent with the redesign's goals.)
2. **Schema/GSI windows.** For changes that add a GSI or alter the GraphQL
   schema, sequence so the new index/schema is live *before* the new code depends
   on it (expand/contract). This is a per-change discipline, not something the
   framework can fully auto-guarantee.
3. **Fast rollback.** Keep the previous version's lifecycle row demotable/revivable
   so a rollback redeploy flips "current" back on its first heartbeat. Under
   Option A this is automatic (newest *connected* wins; if v2 goes away, v1 — if
   still/again connected — becomes current). Under Option B it is the
   "recompute highest live on disconnect" rule.
4. **Idempotent commands** (already a framework convention) so the brief overlap
   window can't double-apply.

### 12.4 Verdict

Zero-downtime is **not a single switch we can flip on**, but the platform is
close: Lambda + data updates are graceful, and the lifecycle handover is
continuous by construction. The remaining gaps are (a) handover lag — closeable
with a deploy-time heartbeat, and (b) schema/GSI propagation — a per-change
expand/contract discipline. The redesign **improves** the guarantee (continuous
manifest handover, automatic rollback) and removes a regression (the retire hook
yanking v1 early). A firm guarantee for *schema-changing* deploys needs the
expand/contract discipline documented as a deploy contract.

## Appendix A — Cross-plugin consistency: when DCB earns its place

§5 parks DCB (Option C) "for a future cross-plugin consistency need." This
appendix makes that concrete — and states the hard limit of what DCB can span.

### A.1 What "cross-plugin consistency" means

An **aggregate** gives you a transactional boundary around **one instance**. A
decision on the `Catalog` aggregate can atomically read and guard `Catalog`'s own
history — and nothing else. It *cannot*, in the same atomic decision, guarantee
anything about `Ordering`'s current state. To coordinate across instances with an
aggregate you must drop to **eventual consistency**: react to another aggregate's
events via an automation slice / policy, accept a window of inconsistency, and
compensate.

A **DCB (Dynamic Consistency Boundary)** decision defines its consistency scope
as a **query over tags** and appends new events **iff that queried state hasn't
changed**. **But — and this is the load-bearing constraint — that optimistic
concurrency is enforced inside a *single event log*.** On AWS it is a
`TransactWriteItems` against one `DcbEventLog` table with per-tag fence sentinels
in that same table
([dcb-dynamodb-consistency-check.md](dcb-dynamodb-consistency-check.md)).
Reventless provisions **one `DcbEventLog` per plugin**
([Plugin_Builder.res:594-601](../../reventless/reventless-core/src/components/Plugin/Plugin_Builder.res#L594)).
Therefore:

> **DCB cannot make a decision consistent across two *different* event logs.**
> Tags only buy you a dynamic boundary *within* the one log they live in. There
> is no atomic boundary spanning, say, Catalog's `DcbEventLog` and Ordering's
> `DcbEventLog`.

A tempting-but-wrong framing is to "tag `extensionPoint=Catalog.Products`
spanning the Catalog and Ordering plugins" — those events live in *separate* logs
and cannot be jointly fenced.

The escape hatch — and the reason cross-plugin *lifecycle* consistency is still
achievable — is **where the relevant events actually live**. Plugin lifecycle
events (`Connected`/`Disconnected`/`Retired`, and the `pluginDefinition` that
declares each plugin's extension points and protocols) are **not** in any
business plugin's domain log. They are owned and **centralised by the
platform/admin** — the Plugin aggregate's EventLog in `Platform_Admin`
([Platform_Admin.res:261](../../reventless/reventless-core/src/admin/Platform_Admin.res#L261)).
All plugin names' lifecycle state therefore already co-resides in **one
admin-owned store**.

That splits "cross-plugin consistency" into two very different cases:

- **(I) Cross-plugin *lifecycle* invariants** — depend only on plugins'
  *registration/connection* state. That state is all in the admin store, so a
  single admin-side decision can enforce them. The mechanism is **admin-local**:
  either a **single `PluginRegistry` aggregate** (one stream owns every plugin's
  lifecycle — strong but serialised) or, if the admin hosts a `DcbEventLog`, an
  **admin-level DCB slice** tagged by `pluginName` / `extensionPointName`
  (selective consistency without serialising everything). **Not** business-plugin
  DCB.
- **(II) Cross-plugin *domain-data* invariants** — depend on the *live domain
  events* of two plugins (an Order in Ordering's log referencing a Product in
  Catalog's log). These are in separate `DcbEventLog`s → **no atomic option
  exists**. Must be **eventual** (automation slice / policy / denormalised
  read-side) — this is the hard limit the one-log-per-plugin topology imposes.

Today's connect-time protocol check already lives on the admin side and is
**eventual detection, not prevention**: on mismatch it emits
`ReportIncompatibility` but *"the connection still proceeds"*
([PluginExtensionPoint_Plugin.res:145-169](../../reventless/reventless-core/src/admin/PluginExtensionPoint_Plugin.res#L145)).
The real design question is which **case-(I)** invariants should become atomic
prevention — and that is an *admin-store modelling* choice, not a business-plugin
DCB question.

### A.2 Examples

Online-shop domain: Catalog provides `Catalog.Products`; Ordering consumes it via
`AvailableProducts`. Each example is tagged **(I)** lifecycle (admin-store,
enforceable) or **(II)** domain-data (cross-log, *not* atomically enforceable).

**Example 1 — Extension/ExtensionPoint protocol integrity. Splits across both cases.**
- **(I) Declared-compatibility at connect** (lifecycle): an Ordering version that
  *declares* it needs `Catalog.Products` command-v2 may connect only if the
  currently-connected Catalog version *declares* it offers v2. Both declarations
  arrive as part of each plugin's `Connect`/`pluginDefinition` into the **admin
  store** → an admin-side decision (registry aggregate or admin DCB slice tagged
  `extensionPointName`) can enforce this atomically.
- **(II) Live-data compatibility** (domain): an actual `Order` line in Ordering's
  `DcbEventLog` referencing an actual `Product` in Catalog's `DcbEventLog`. These
  are **separate logs** → no atomic DCB. Eventual only (projection /
  policy / denormalised `AvailableProducts`). This is the case the per-plugin-log
  constraint rules out.

**Example 2 — Single-owner uniqueness of an extension-point name. (I) lifecycle.**
- *Invariant:* at most one connected plugin may **provide** a given EP name.
- *Why it's enforceable:* every plugin's EP declarations are in the admin store
  (via `Connect`). The admin already routes commands by scanning for the first
  connected provider — `forwardCommand` picks `plugins[0]`
  ([PluginExtensionPoint_Plugin.res:28-44](../../reventless/reventless-core/src/admin/PluginExtensionPoint_Plugin.res#L28)),
  so two providers → **nondeterministic routing (a real latent bug today)**.
- *Mechanism:* admin-side — a `PluginRegistry` aggregate, or an admin DCB slice
  tagged `extensionPointName`, rejects a second claimant. **No business-plugin
  DCB involved.**

**Example 3 — Atomic activation of a declared dependency set. (I) lifecycle.**
- *Invariant:* Ordering may be `Connected` only if Catalog **and** Customers are
  `Connected` at compatible versions.
- *Why it's enforceable:* the connected-state of all three names lives in the
  admin store → one admin-side decision sees them all.
- *Mechanism:* admin registry aggregate / admin DCB slice tagged `pluginName`.

**Example 4 — Coordinated platform epoch. (I) lifecycle.**
- *Invariant:* advancing to protocol epoch N rejects mixed-epoch plugins.
- *Why it's enforceable:* every plugin's declared epoch is in the admin store
  (registration), so the constraint is admin-local, not cross-log.

### A.3 The decision heuristic (corrected for the one-log-per-plugin constraint)

| Invariant scope | Where the events live | Mechanism |
|---|---|---|
| Within one plugin **name** (current version, connect/disconnect/retire/rollback) | admin store | **The §5 lifecycle redesign** — Options A / A′ (recommended) / B. *Today's requirement.* |
| Across plugin **names**, but only over **lifecycle/registration** state, atomic | admin store, many streams in **one** log | **Admin-side**: single `PluginRegistry` aggregate, **or** admin-level DCB slice (if the admin hosts a `DcbEventLog`) tagged `pluginName`/`extensionPointName`. **Not** business-plugin DCB. |
| Across plugins' **domain data** (live events in different plugins) | **separate** `DcbEventLog`s | **No atomic option** — DCB cannot span logs. Eventual: automation slice / policy / denormalised read-side. |

The middle row is the only place "DCB" legitimately appears for cross-name work,
and even there it is an **admin-log** DCB slice, never a tag spanning business
plugins' logs.

### A.4 Why this does *not* change today's recommendation

The current requirement — "one current version per plugin name, no duplicate
menus" — is wholly **within a single plugin name** → the §5 lifecycle redesign
(**Option A′**, recommended) is the correct choice. No DCB, no cross-log anything.

If a **case-(I)** cross-name invariant later becomes a hard requirement (most
plausibly Example 2's EP-name uniqueness, or Example 3's dependency set), the
realistic choices are both **admin-local**: fold lifecycle into a **single
`PluginRegistry` aggregate**, or give the admin a `DcbEventLog` and model
lifecycle as an **admin DCB slice**. Business-plugin DCB is **off the table by
construction** — one `DcbEventLog` per plugin means no atomic boundary spans two
of them. And **case-(II)** cross-plugin *domain* consistency has **no** atomic
mechanism at all in this architecture; it is necessarily eventual.

Independent of all this: **Example 2's nondeterministic `plugins[0]` routing is a
real latent bug today** and worth tracking on its own.
