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

> **The heartbeat carries only the `name@version` id — not the
> `pluginDefinition`.** The definition (structure, schema fragment, UI fragments,
> extension points/protocols) is delivered by the **`Connect` handshake**, which
> the plugin's own EventCollector answers. **A new version therefore must re-run
> the handshake to deliver its current details — they may differ from the
> previous version, and are never inherited.** Any redesign must keep this: a
> heartbeat for a not-yet-connected version *triggers a fresh connect*, it does
> not by itself make that version current.

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
removes the *causes*. Under the recommended **Option B** all four collapse into a
single name-level owner: one aggregate keyed by `name` (addresses row 1), which
decides supersession on the write side (rows 2 and 4) and projects one
authoritative `current` row per name (row 3). The minimal **Option A** instead
keeps row 1 (per-version aggregate) and addresses rows 2–4 via the deleted hook +
the name-keyed `current` projection.

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

### Option A — read-model differentiation (supersession *inferred*; baseline)

Treat **a plugin version as the entity** (as today; aggregate keyed by
`name@version`). Move only "which version is current" to the **read side**: a
`Plugins` projection keyed by `name` folds all versions' events and keeps the
**highest currently-connected** version (`Plugin.compareVersions`; on disconnect,
fall back to the next-highest connected → rollback). It carries a small per-name
`{version → status}` map to compute that.

- **Supersession is *inferred* in the projection** — there is no `Superseded`
  event. The projection promotes a version only on its **`Connected` event**
  (which carries the fresh definition from the handshake — §2.2), so a new
  version's heartbeat alone never makes it current; its post-handshake `Connected`
  does. Changed details are captured automatically.
- **Pro:** least rework; robust even if a heartbeat timeout misfires (a stale
  lower version is never the highest connected, so never surfaces); the
  stray-heartbeat-revival race is harmless for the same reason.
- **Con:** no first-class supersession event → only a *thin*, reconstructed audit
  history and **no clean migration hook** (§6.2.3). This is the **baseline / first
  increment** — not a destination once a rich history is wanted.

### Option B — a single name-level lifecycle owner (recommended)

**One** component owns a plugin's whole lifecycle for a name — connect, heartbeat,
supersede, disconnect, manual retire — deciding **synchronously** and emitting one
ordered stream of intentful events (`VersionConnected`, `VersionSuperseded(from,
to)`, `VersionPromoted`, `Disconnected`, `Retired`, …). The `current` view **and**
the rich `PluginHistory` (§6) are then faithful folds of that one stream.

- **Pro:** one decider, one consistency boundary (the plugin name), **one linear
  audit stream** → "exactly one current" is an **enforced invariant** and the rich
  history is clean — no inference, no cross-component seam. Best fit for the
  rich-history goal (§6.2).
- **Cost:** heartbeats route to the `name` id (version carried in payload) — modest
  rewiring; per-version lifecycle logic lives in the one owner. (Migration of
  existing streams is not a concern — §5 preamble.)

**Two implementations of the single owner:**

- **B-agg — aggregate keyed by `name` (default, recommended).** The boundary is
  exactly one plugin name: a static, self-contained aggregate root — the textbook
  aggregate. State `{ current, known: dict<version, {definition, status,
  lastHeartbeatAt}> }`. Because a heartbeat carries only the id, not the
  definition (§2.2):
  - `Heartbeat(V)` for a **not-yet-connected** version → emit `VersionDetected(V)`
    and run the **same `ConnectPlugin` handshake as today**; the plugin replies
    `Connect(V, definition)` → `VersionConnected(V, def)`, and if `V > current`
    also `VersionSuperseded(prev)` with `current := V`. **The new version's
    (possibly changed) definition is re-delivered here, never inherited.**
  - `Heartbeat(V == a connected version)` → keep-alive (refresh
    `lastHeartbeatAt`); no event.
  - `Heartbeat(V)` from a stale **lower** version → ignored (liveness only).
  - timeout on `current` → promote the highest still-live **connected** version
    (rollback), reusing *its* stored definition.
  Simplest correct choice for per-name lifecycle. (Note: the detection→connect
  arc, trivial in today's per-version model, must be explicit here — see §9.)
- **B-dcb — DCB `StateChangeSlice` in the admin `DcbEventLog`, tagged
  `pluginName`.** Same single-name boundary expressed via tags; for *pure*
  per-name lifecycle it buys nothing over B-agg. Choose it **only if** lifecycle
  decisions must also read **across names** — reject connect when another
  connected plugin already owns an extension-point name, enforce dependency sets
  (Appendix A, case I). Then one slice tagged `pluginName` + `extensionPointName`
  enforces single-name lifecycle *and* those cross-name invariants. **This
  subsumes what earlier drafts called "Option C".**

### Option A′ — per-version aggregates + a name-level reactor (variant; *not* recommended)

A two-component variant of B that **keeps the existing per-version aggregates**
(`name@version`) and adds a separate name-level reactor consuming their
`Connected` / `Disconnected` events and emitting the supersession events. Its only
advantage is **avoiding the aggregate re-key / heartbeat rewiring**.

Since **migration is not a constraint here**, that advantage is moot — and the
split costs: two write-side deciders for one concept, an **eventual-consistency
seam** (the reactor lags the per-version events), and a history assembled from N
per-version streams **plus** the reactor's stream instead of one. Pick A′ **only**
if you are forced to keep the `name@version` aggregate identity (you are not).

### 5.1 Contrast

Migration omitted (not a deciding factor); "rework" is code change, not data
migration. B's implementation (B-agg vs B-dcb) is a sub-choice below the table.

| Dimension | **Option A** | **Option B** *(recommended)* | **Option A′** *(variant)* |
|---|---|---|---|
| Supersession decided | read-side, **inferred** | **write-side, one owner** | write-side, a separate reactor |
| `VersionSuperseded` event | none | **yes** | yes |
| Rich audit history | thin (reconstructed) | **one faithful stream** | faithful, but from 2+ streams |
| "Exactly one current" | eventual *view* | **enforced invariant** | eventual *intent* (2 components) |
| Write-side components | per-version aggregates | **one** (`name` owner) | per-version aggregates **+ 1** |
| Heartbeat routing | unchanged | re-route to `name` | unchanged |
| When to pick | minimal bug fix only | **default** | only if `name@version` identity must stay |

### 5.2 Recommendation

**Option B, as a name-keyed aggregate (B-agg).** With migration not a factor, the
cleanest design is a *single* owner of the plugin lifecycle: one decider, one
consistency boundary, **one linear audit stream** — which is exactly what makes
the rich history (§6.2) and the enforced single-current invariant fall out for
free. The two-component split (A′) only ever existed to dodge the aggregate
re-key; with an alpha wipe acceptable, that economy is gone and the split just
adds an eventual-consistency seam and a multi-stream history.

- Reach for **B-dcb** (a DCB slice tagged `pluginName` [+ `extensionPointName`])
  **only if** cross-*name* lifecycle invariants (Appendix A) are on the roadmap;
  otherwise the aggregate is simpler.
- **Option A** remains the minimal duplicate-menu fix and a sensible **first
  increment** (ship the name-keyed current projection + hook deletion), with B
  layered on when the rich-lifecycle/history work begins.
- **Option A′** is documented as a variant for the migration-constrained case
  only — which this is not.

Steps: §8. Bug recap: §7.

## 6. Read-model / state-view design (two projections)

Both projections consume the Plugin lifecycle events. Under **Option B
(recommended)** the name-level owner emits one ordered stream including the
explicit `VersionSuperseded` / `VersionPromoted` events — this is what makes the
rich history in §6.2 a faithful fold. Under **Option A** there are only the
existing per-version events (`Connected` / `Disconnected` / `Deactivated` / manual
`Retire`), and supersession is *inferred* in the projection (§6.2.3). (The A′
variant emits the same events as B but from a separate reactor.)

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
States are **per-version** (`name@version`) and separate **automatic** from
**manual (admin)** transitions. *"In active view?"* means the AutoUI nav + the
live-plugins listing — **`PluginHistory` always retains every state** (it is the
immutable audit trail; see below).

| State | Trigger | Kind | In active view? | Auto-revivable by its own heartbeat? |
|---|---|---|---|---|
| `Connected` | heartbeat handshake | auto | yes (current if highest) | — |
| `Disconnected` | heartbeat **timed out** | auto | yes (shown, unavailable) | **yes** — reconnects on next heartbeat |
| `Superseded` | a **newer version connected** | auto (deploy) | yes (not current) | yes (rollback / re-promotion) |
| `Inactive` | admin **Deactivate** | manual | yes | no — admin `Activate` |
| `Retired` | admin **explicitly retires that version** | **manual** | no (archived) | **no** — admin un-retire, *or just deploy a different version* |

Clarifications (correcting earlier drafts):

- **`Disconnected` ≠ gone.** A timed-out version stays in the system (listed,
  greyed) and reconnects if it heartbeats again. Not removed.
- **`Retired` is a deliberate, per-*version* admin act, not a deploy artifact.**
  Today's code overloads `Retired` to mean "auto-superseded by a newer version";
  that automatic concept is renamed **`Superseded`**, freeing `Retired` for the
  manual "archive this specific version" decision. (An earlier draft suggested
  *dropping* `Retired` — wrong; keep and promote it.)
- **A retired version is still in `PluginHistory`.** Retirement is *itself* a
  recorded event, so the version is *more* represented in the audit trail, not
  less. "Archived" means hidden from the **active view**, never erased from
  history.
- **Retirement never blocks the plugin name.** Because `Retired` is keyed to one
  `name@version`, a **new version is a fresh identity**: its heartbeat runs the
  normal connect handshake (§2.2) and becomes current regardless of any older
  version being retired. "Not auto-revivable" applies only to the *exact* retired
  version — a stray heartbeat *for that version* is ignored (the deliberate
  contrast with `Disconnected`). So the plugin is never permanently bricked: ship
  a new version, or admin-un-retire the old one. See §6.2.6.

This is what makes the lifecycle rich: an admin reviews the `Disconnected` /
`Superseded` old versions and *chooses* to `Retire` (archive) the dead ones — a
manual cleanup step, recorded as an intentful event.

#### 6.2.2 Two consumers, two views

- **AutoUI nav manifest** (§6.1): only the **current `Connected`** version per
  name. `Disconnected` / `Superseded` / `Inactive` / `Retired` never appear in
  navigation — this is the duplicate-menu fix.
- **Admin plugin-lifecycle view** (`PluginHistory`): **all** versions in **all**
  states — `Connected` / `Disconnected` / `Superseded` / `Inactive` **and
  `Retired`** — plus the transition timeline. Retired versions remain here
  permanently (the audit trail); the admin uses this view to see what is
  disconnected/superseded and decide what to retire, and to read the full history
  of a since-retired version.

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
- **Option B** *decides* supersession on the write side and emits an intentful
  **`VersionSuperseded(from: v72, to: v73, at: T)`** (carrying both definitions)
  into **one ordered stream**. History becomes a faithful fold — zero inference —
  and that event is the natural migration trigger (§6.2.4). (The A′ variant emits
  the same event but from a separate reactor, so the history is assembled from two
  streams; see §5.)

**Verdict:** a rich, queryable, migration-driving history requires supersession
to be a *decided* event — i.e. **Option B (recommended)**, not Option A. You can
only faithfully project events you actually decide on the write side, and B's
single stream is the cleanest source for it.

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

#### 6.2.6 Retirement & re-admission semantics

Retirement is **per-version**; the plugin **name** is never permanently blocked.

- **Retire `Catalog@v72`** (admin) → v72 → `Retired`: gone from the active view,
  still in `PluginHistory`. A stray *v72* heartbeat is **ignored** (the
  deliberate contrast with `Disconnected`, which auto-reconnects) — so a
  superseded zombie can't resurrect itself.
- **Heartbeat for a *new* version (`Catalog@v75`)** → `v75` is a distinct
  identity, unaffected by v72's retirement: it runs the normal detect→connect
  handshake (§2.2), delivers its own definition, and becomes current. **The
  plugin is never bricked** — to re-introduce it you simply deploy a (new or
  higher) version.
- **Re-introducing the *exact* retired version (`v72`)** is the only case that
  needs intent: a deliberate **admin un-retire** (or treat a fresh `Connect` —
  not a bare heartbeat — as re-admission). Stray heartbeats alone won't do it.

What this implies for the owner (Option B): `Retired` is a **per-version
sub-state inside the name-keyed aggregate's `known` map**, *not* a terminal state
of the whole aggregate. The name aggregate keeps accepting and promoting new
versions while individual old versions sit `Retired`. (In A / A′, `Retired` is
naturally a state of the per-version `name@version` instance, with the same
effect.)

> **Decommissioning a whole plugin name** (rare: "remove Catalog entirely, reject
> even new versions") is a *separate* admin operation, deliberately out of scope
> here. If added, it must carry an explicit **re-admit** path — never a permanent
> brick. Tracked as an open question (§9).

### 6.3 ReadModel vs StateViewSlice

- Under **Options A / A′ / B (aggregate-based)**, both views are **ReadModels** —
  the idiomatic projection for an aggregate, queryable over GraphQL.
- Under **B-dcb (the DCB-slice implementation of Option B)**, the equivalents are
  **StateViewSlices** (the DCB-world projection). The two views map cleanly either
  way.

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

**Step 2 — Option B (recommended target): the single name-level owner.**
- Implement the lifecycle owner as a **name-keyed aggregate (B-agg)**: re-key
  `name@version → name`, **wipe** the Plugin EventLog + Plugins QueryDb (plugins
  re-register via heartbeat — migration is not a concern here), and **re-route
  heartbeats** to the `name` id (version in payload) in `PluginRuntime_Builder` /
  `Plugin_Builder`.
- The aggregate decides the whole lifecycle and emits one ordered stream
  (`VersionConnected` / `VersionSuperseded` / `VersionPromoted` / `Disconnected` /
  `Retired`). Point both `current` and `PluginHistory` (§6) at that stream.
- **B-dcb instead** only if cross-*name* invariants are wanted: implement the
  owner as a DCB `StateChangeSlice` in the admin `DcbEventLog` tagged `pluginName`
  (+ `extensionPointName`) — see Appendix A.

**Variant — Option A′ (only if the `name@version` identity must be kept).**
- Skip the re-key/rewiring: keep the per-version aggregates and add a name-level
  reactor that consumes their `Connected` / `Disconnected` events and emits
  `VersionSuperseded` / `VersionPromoted`. Accept the eventual-consistency seam and
  the multi-stream history. Not recommended here (no identity constraint).

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
6. **B implementation — aggregate (B-agg) or DCB slice (B-dcb)?** Default to the
   name-keyed aggregate; choose the admin DCB slice only to fold in cross-*name*
   invariants (Appendix A). (Only if the `name@version` identity must be kept does
   the A′ reactor — aggregate vs automation slice — come into play.)
7. **Manual `Retire` UX & authority.** Where does the admin `Retire` command live
   (per-version aggregate, today), and what gates it (admin authz)? Define the
   archive semantics (`Retired` removed from listings, not auto-revivable).
8. **Per-version detection→connect arc inside the name owner (B).** A heartbeat
   carries no definition (§2.2), so the name-keyed aggregate must, on a heartbeat
   for an unconnected version, run the `ConnectPlugin` handshake to fetch *that
   version's* definition before promoting it. Confirm how that handshake routes
   to a `name`-keyed instance (today it keys on `name@version`) and that the new
   version is not surfaced as current until its `Connect` lands. (A′ keeps this
   trivial — each version is still its own per-version aggregate.)
9. **Cross-name consistency on the horizon?** If EP-name uniqueness / dependency
   sets (Appendix A) become hard requirements, implement Option B as **B-dcb** (a
   DCB slice tagged `pluginName` + `extensionPointName`) rather than B-agg.
10. **Whole-name decommission (§6.2.6)?** Do we need an admin op to retire a
    plugin *name* (reject even new versions), distinct from per-version `Retire`?
    If yes, it must carry an explicit **re-admit** path (never a permanent brick),
    and the name owner needs a "decommissioned, ignore heartbeats until re-admit"
    state. Default for now: *no* — per-version `Retire` + "new version always
    connects" covers the real cases.

## 10. TL;DR

- **Decision: Option B — a single name-level lifecycle owner, as a name-keyed
  aggregate.** It owns the whole lifecycle and emits one ordered stream including
  explicit `VersionSuperseded` / `VersionPromoted`, so the `current` view and the
  rich `PluginHistory` are faithful folds and "one current version" is an enforced
  invariant. Use a **DCB slice (B-dcb)** instead only if cross-*name* invariants
  are wanted (Appendix A). **Option A** (read-side inferred supersession) is the
  minimal duplicate-menu fix / first increment; **A′** (per-version aggregates +
  reactor) is a variant only for the migration-constrained case — which this is
  not. Migration is not a deciding factor. Contrast: §5.1; reasoning: §5.2; steps:
  §8.
- **Why it works:** "which version is current" stops being inferred at query time
  from a pile of per-version `Connected` rows and becomes one authoritative row
  per plugin — duplicate menus impossible by construction; supersession is a
  recorded event, not a read-side guess.
- **Lifecycle:** distinguish auto `Disconnected` (heartbeat timeout, still listed)
  from auto `Superseded` (newer version) from manual `Retired` (admin "really
  gone", per-version, archived-from-active-but-kept-in-history) — §6.2.1.
  Retirement is per-*version*: a new version always connects, so the plugin name
  is never bricked (§6.2.6). This richer model is the reason a write-side owner
  (B) — supersession as a decided event — beats inferring it read-side.
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
| Lifecycle/manifest (Plugin aggregate + current view) | v1 stays current until v2's connect handshake completes | **No gap** — see 12.2 |

### 12.2 The lifecycle handover is *continuous* (and the redesign keeps it so)

Because v2 becomes `Connected` only after its **first heartbeat triggers the
connect handshake** (which re-delivers v2's possibly-changed definition — §2.2)
and v1 remains `Connected` until its **timeout**, there is a natural overlap
during which the "current" view always serves a working plugin definition:

- **Before v2's connect completes:** current = v1 (its code is being replaced, but
  its lifecycle row and manifest entry are intact). The SPA keeps rendering v1's
  UI/schema.
- **After v2's `Connect` lands:** current flips to v2, and the manifest now serves
  **v2's fresh definition** (new UI/schema). v1's row later `Disconnected`s on
  timeout.

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

§5 defers cross-*name* invariants to **B-dcb** (the DCB-slice implementation of
the single name-level owner) "for a future cross-plugin consistency need." This
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
| Within one plugin **name** (current version, connect/disconnect/retire/rollback) | admin store | **The §5 lifecycle redesign** — Option B (recommended; A is the minimal baseline, A′ a variant). *Today's requirement.* |
| Across plugin **names**, but only over **lifecycle/registration** state, atomic | admin store, many streams in **one** log | **Admin-side**: single `PluginRegistry` aggregate, **or** admin-level DCB slice (if the admin hosts a `DcbEventLog`) tagged `pluginName`/`extensionPointName`. **Not** business-plugin DCB. |
| Across plugins' **domain data** (live events in different plugins) | **separate** `DcbEventLog`s | **No atomic option** — DCB cannot span logs. Eventual: automation slice / policy / denormalised read-side. |

The middle row is the only place "DCB" legitimately appears for cross-name work,
and even there it is an **admin-log** DCB slice, never a tag spanning business
plugins' logs.

### A.4 Why this does *not* change today's recommendation

The current requirement — "one current version per plugin name, no duplicate
menus" — is wholly **within a single plugin name** → the §5 lifecycle redesign
(**Option B**, recommended) is the correct choice. No DCB, no cross-log anything
*unless* cross-name invariants are wanted, in which case B's DCB implementation
(B-dcb) is exactly the admin-side slice described here.

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
