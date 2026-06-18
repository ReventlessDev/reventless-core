# Plan (Backlog): PluginHistory Indices & Lifecycle Dashboards (Part 2b)

**Status:** Backlog (not started)

**Depends on:**
- [plugin-history-parity-gap.md](../plugin-history-parity-gap.md) **Part 1** — admin
  read models emit `By<Index>` query fields from `@index` (without this, GSIs on an
  admin read model would re-hit the SDL/resolver mismatch).
- [plugin-history-parity-gap.md](../plugin-history-parity-gap.md) **Part 2** —
  `PluginHistory` is a visible composite-key admin read model.

**Analysis:** [plugin-history-view-design.md](../../analysis/plugin-history-view-design.md)
(§5 read-model-driven opportunities), [plugin-lifecycle-redesign.md](../../analysis/plugin-lifecycle-redesign.md)
(§6.2.4 — the opportunity catalogue).

---

## Goal

Turn `PluginHistory` from a flat audit list into a **queryable operational dataset**:
add Global Secondary Indexes (and a couple of derived fields) so the lifecycle trail
can be sliced by the dimensions that power admin dashboards — **by state, by time,
and optionally by actor / version** — all through the standard auto-generated
`By<Index>` query path (no scans, no Lambdas). Indices are added **incrementally**,
one per concrete dashboard, because each GSI costs storage + write amplification.

This is the "opportunity layer" of the lifecycle redesign: §6.2.4 listed *what* a
rich history unlocks; this plan says *how* (which key/index serves which dashboard)
and *what extra* (summary projections / counters) is needed where indices alone
don't suffice.

---

## 0. Base table recap (the starting point)

After Part 2, `PluginHistory` is keyed:

- **PK** `name` (plugin name) · **SK** `transitionKey` = `version#transitionAt#transition`
- Already supports: per-plugin timeline (`<single>Items(name)` / PK query), global
  feed (scan), and `list` filter/sort on `name` / `transition` / `transitionAt`.

So before adding any GSI, the *per-plugin* and *basic filtered* views already work.
GSIs exist to make **cross-plugin, by-dimension** reads efficient.

---

## 1. Access-pattern catalogue (what we want to ask)

| # | Question (dashboard) | Access pattern | Served by |
|---|---|---|---|
| Q1 | "Show Catalog's full timeline" | PK query on `name` | base table (Part 2) |
| Q2 | "Everything platform-wide, newest first" | scan / time index | base scan, or `byDay` (Q5) |
| Q3 | "All **supersessions** (deploys) this week" | `transition = Superseded`, time-bounded | **`byTransition`** |
| Q4 | "All versions that ever **Disconnected** but were never **Retired**" (drift) | `transition` filter + correlation | **`byTransition`** + logic |
| Q5 | "What happened on 2026-06-18 / deploy frequency per day" | time-bucketed range | **`byDay`** |
| Q6 | "What did admin *alice* change" (compliance) | PK query on actor | **`byActor`** (optional) |
| Q7 | "Full lifecycle of Catalog@1.2.3" | PK query on `name#version` | base (`<single>Items` + filter) or **`byVersion`** (optional) |
| Q8 | "Mean version lifetime / time-to-connect / time-superseded→promoted" | aggregate over event *pairs* | **summary projection** (§4) — not a GSI |

---

## 2. Proposed indices

Each GSI is generated from `@index("<name>")` on the partition field +
`@indexSubId("<name>")` on the sort field (CLAUDE.md PPX rules); Part 1 emits the
matching `Platform_PluginHistoryBy<Name>` query field.

### 2.1 `byTransition` — slice by lifecycle event kind (recommended first)

- **Keys:** PK `transition`, SK `transitionAt`.
- **Generated query:** `Platform_PluginHistoryByTransition(transition, …, range on transitionAt)`.
- **Unlocks:** Q3 (deploy/supersession feed), Q4 (drift candidates: scan
  `Disconnected`), retirement audit (`Retired`), incompatibility log
  (`IncompatibleDetected`), connect activity (`Connected`).
- **Cost:** low cardinality PK (9 transition kinds) → a few warm partitions; fine at
  admin volume. Use `projectionType: KEYS_ONLY` or `INCLUDE(name, version)` to keep
  it cheap if full item isn't needed.

### 2.2 `byDay` — slice by time window (recommended second)

- **Keys:** PK `day` (derived `YYYY-MM-DD` from `transitionAt`), SK `transitionAt`.
- **Requires:** a derived `day` field on the state (projection computes
  `transitionAt[0:10]`).
- **Generated query:** `Platform_PluginHistoryByDay(day, …, range on transitionAt)`.
- **Unlocks:** Q2/Q5 — global chronological feed and per-day deployment-frequency /
  SLA charts; time-window audit; bounded reads (one partition per day) instead of a
  growing full-table scan.
- **Cost:** good distribution (one partition/day); naturally time-bounded; pairs
  well with a TTL.

### 2.3 `byActor` — slice by who acted (optional, compliance)

- **Keys:** PK `by` (actor), SK `transitionAt`.
- **Unlocks:** Q6 — per-actor audit ("everything alice did"); admin-action
  compliance trails.
- **Cost / caveat:** system transitions use `"Heartbeat"` / `""` → a hot partition;
  consider excluding system actors from the index (only project admin-initiated
  `Activate`/`Deactivate`/`Retire`) via a sparse index (only set the indexed
  attribute on admin actions). Lower priority.

### 2.4 `byVersion` — version-centric lifecycle (optional)

- **Keys:** PK `name#version` (derived), SK `transitionAt`.
- **Unlocks:** Q7 — a single version's full lifecycle in one query (time-to-connect,
  connected→superseded gap).
- **Note:** largely covered already by `<single>Items(name)` + client filter on
  `version`; add only if version-scoped pages become first-class. Lowest priority.

---

## 3. Derived fields (projection additions)

To key the indices above, `PluginHistoryProjection` writes a few computed fields
alongside the existing ones:

- `day` (for `byDay`) = `transitionAt[0:10]`.
- `nameVersion` (for `byVersion`, if pursued) = `${name}#${version}`.
- (`byActor` reuses the existing `by`.)

These are pure functions of data already on the row — no new event shape.

---

## 4. Beyond indices — aggregate/metric opportunities (Q8 and friends)

GSIs serve **filtered retrieval**. Several high-value opportunities are
**aggregations over event pairs** that indices alone don't compute. Two mechanisms:

### 4.1 A version-lifecycle **summary** read model (one row per `name#version`)

A second projection off the same Plugin event stream that *folds pairs* into a
summary row:

- on `VersionConnected(v)` → record `connectedAt`;
- on `VersionSuperseded(prev→v)` → set `prev.supersededAt`, compute
  `prev.activeDurationMs`;
- on `VersionDisconnected(v)` / `VersionPromoted` → close/relate intervals;
- derive `timeToConnectMs` (deploy heartbeat → connected), `connectedDurationMs`,
  `supersededToPromotedMs` (rollback latency).

**Unlocks:** **deployment/SLA metrics** (mean version lifetime, deploy→connect lag),
**rollback intelligence** (a small `supersededToPromotedMs` = a fast rollback → bad
release), **incident debugging** (interval reconstruction). This is a read model, so
it ships through the same parity-gap path — still no Lambda.

### 4.2 Counters for cheap rolling aggregates

Use the framework `Counter` component for O(1) tallies that don't need per-row
retrieval: total deploys, supersessions per plugin, retirements — surfaced as
headline numbers without scanning the history.

---

## 5. Opportunities deep-dive (mapped to mechanism)

| Opportunity (§6.2.4) | What it gives operationally | Mechanism here |
|---|---|---|
| **Audit & compliance** | immutable who/what/when of every deploy/supersede/retire | base table + `byActor` (per-actor), `byDay` (per-window) |
| **Status dashboards** | historical state activity (connects, disconnects, retirements) | `byTransition` (current state still from the `Plugins` view) |
| **Deployment / SLA metrics** | deploy frequency, deploy→connect lag, mean version lifetime, supersession rate | `byDay` (frequency) + **summary projection** (§4.1) + counters (§4.2) |
| **Rollback intelligence** | "v73 rolled back 4 min after taking over" → flag bad release | **summary projection** `supersededToPromotedMs`; or a stream reactor (Part 3 / migration automation) |
| **Incident debugging** | reconstruct a handover / dual-connected window from the timeline | base timeline + `byDay` / `byTransition` slices |
| **Drift / zombie detection** | lingering `Connected`, `Disconnected`-never-`Retired` | `byTransition` (Disconnected feed) + correlation with the current view |
| **Version diffing / breaking-change** | v→v structure & schema diffs, changelogs | **primarily stream-driven** (`VersionSuperseded` carries both `pluginDefinition`s); history view *surfaces* the diffs |

Key takeaway: **`byTransition` + `byDay` + a version-lifecycle summary projection**
cover the large majority of the operational value; `byActor` / `byVersion` /
counters are targeted add-ons.

---

## 6. Incremental rollout

Add only what a concrete dashboard needs, in this order:

1. **`byTransition`** — highest reuse (deploy feed, drift, retirement/incompat logs).
2. **`byDay`** (+ `day` field) — time-window feed + deploy-frequency charts.
3. **Version-lifecycle summary projection** (§4.1) — the SLA/rollback metrics.
4. **Counters** (§4.2) — headline tallies.
5. **`byActor`** / **`byVersion`** — only if per-actor / per-version pages are built.

Each: `@index` annotation (or new projection) → build green → deploy → verify the
`By<Index>` query resolves and the dashboard renders.

---

## 7. Risks & considerations

- **Hot partitions:** low-cardinality GSI PKs (`transition`, `by`) concentrate
  writes. Acceptable at admin volume; for `byActor` use a **sparse** index
  (admin-initiated rows only). `byDay` distributes well.
- **Write amplification & cost:** each GSI is written on every matching item. Prefer
  `KEYS_ONLY` / `INCLUDE(<minimal>)` projection types unless the dashboard needs the
  full item.
- **Unbounded growth + retention:** the base table and every GSI grow per transition
  forever. This plan strengthens the case for a **TTL / pruning** policy (open
  question in the parity-gap plan); `byDay` makes time-based pruning natural.
- **AutoUI vs custom dashboard:** AutoUI renders the `list` page; the richer
  `By<Index>` / summary views may need dedicated admin UI surfaces (separate, and —
  per the no-Lambda principle — still served by standard resolvers, just consumed by
  bespoke UI). Decide per dashboard.

---

## 8. Open questions

1. Which dashboards are actually wanted first? (Drives index order; YAGNI otherwise.)
2. Retention/TTL policy — required before the table + GSIs grow unbounded.
3. Are the SLA/rollback metrics (summary projection) in scope, or is the filterable
   audit list enough for now?
4. Does the rollback-alerting opportunity belong here (summary projection) or as a
   stream reactor alongside migration automation (Part 3 / separate analysis)?
