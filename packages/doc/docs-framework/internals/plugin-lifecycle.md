---
title: Plugin Lifecycle
draft: false
---

# Plugin Lifecycle

How a plugin **version** goes from "deployed" to "live" to "superseded / retired",
how the framework tracks that, and how it is surfaced through GraphQL and the admin
AutoUI. This is the conceptual companion to the [Plugin component](/app/components/plugin)
page — that page covers what a plugin *is*; this page covers how its **versions live
and die** at runtime.

The lifecycle is **event-sourced** by a single name-keyed aggregate and projected into
two read models. Almost every subtle behaviour below follows from one invariant:

> **`Connected` ⟺ that version's deployed infrastructure is alive and heartbeating.**

Hold that invariant in mind; the rest is consequences of it.

---

## 1. The states

A plugin name can have many versions, each in one of a small set of states. Two
vocabularies exist, deliberately:

- The **aggregate / `Plugins` read model** status — the live operational state of a
  version: `Connected`, `Disconnected`, `Inactive`, `Retired` (`PluginsReadModelSpec.status`
  / `PluginBehavior.status`).
- The **`PluginHistory`** transition kinds — the full audit vocabulary, including
  states that are *derived* rather than stored: `Detected`, `Connected`, `Superseded`,
  `Promoted`, `Disconnected`, `Activated`, `Deactivated`, `Retired`,
  `IncompatibleDetected`.

```d2
Detected: Detected
Connected: Connected
Disconnected: Disconnected
Inactive: Inactive
Retired: Retired

Detected -> Connected: connect handshake
Connected -> Disconnected: "heartbeat timeout / Disconnect"
Disconnected -> Connected: "Heartbeat (reconnect)"
Connected -> Inactive: "Deactivate (admin)" { class: command-flow }
Inactive -> Connected: "Activate (admin)" { class: command-flow }
Connected -> Retired: "Retire (admin)" { class: command-flow }
Disconnected -> Retired: "Retire (admin)" { class: command-flow }
```

| State | Meaning | Entered by |
|---|---|---|
| `Detected` | A version was observed (handshake trigger) but not yet connected. | `VersionDetected` |
| `Connected` | Deployed, heartbeating, eligible to be the current version. | `VersionConnected` / `VersionActivated` / `VersionPromoted` |
| `Superseded` | **Derived, not stored.** A still-`Connected` version that is *not* the current one (a higher version is current). Recorded as an explicit edge only in `PluginHistory`. | derived: `Connected && version != current` |
| `Disconnected` | Heartbeats stopped — infra torn down, or the Scheduler timed it out. | `VersionDisconnected` |
| `Inactive` | Admin suspended the version (`Deactivate`). Not heartbeat-revivable. | `VersionDeactivated` |
| `Retired` | Admin archived the version (`Retire`), or supersession retired an old one. Terminal. | `VersionRetired` |
| `IncompatibleDetected` | A version was rejected at the handshake (protocol incompatibility). | `IncompatiblePluginDetected` |

---

## 2. The write side — one name-keyed aggregate

The Plugin aggregate is keyed by plugin **name**, *not* `name@version`. A single
instance owns the whole version timeline for that name.

Its state is `known: dict<version → knownVersion>` plus a **derived** `current`
pointer. `current` is always recomputed as *"the highest version whose status is
`Connected`"* — never compared against wall-clock time, so **replay is
deterministic**.

**Commands** (`PluginSpec.command`):

| Command | API-exposed? | Purpose |
|---|---|---|
| `Heartbeat(version)` | `@noApi` (internal protocol) | Liveness ping from a deployed version. |
| `Connect(pluginDefinition)` | `@noApi` | Connect-handshake completion. |
| `Disconnect(version)` | `@noApi` | Graceful drop / Scheduler timeout. |
| `Activate(version)` | ✅ | Admin un-suspend (`Inactive → Connected`). |
| `Deactivate(version)` | ✅ | Admin suspend (`Connected → Inactive`). |
| `Retire(version)` | ✅ | Admin archive (manual). |
| `ReportIncompatibility(pluginDefinition)` | `@noApi` | Handshake rejected a version. |

**Events** (`PluginSpec.event`): `VersionDetected`, `VersionConnected`,
`VersionSuperseded`, `VersionPromoted`, `VersionDisconnected`, `VersionActivated`,
`VersionDeactivated`, `VersionRetired`, `IncompatiblePluginDetected`, plus the
`UIFragment*` events (UI-manifest lifecycle, orthogonal to version status).

### Key behaviours (all in `PluginBehavior`)

- **`current` is derived, never commanded.** Supersession is *not* a command — a
  version that is `Connected` but not `current` is "superseded", a label the read
  side derives. The aggregate stays minimal.
- **Heartbeat semantics depend on prior status:** `Connected` → keep-alive (`Ok([])`);
  `Disconnected` → **reconnect** (re-emits connect events); `Inactive`/`Retired` →
  ignored (those are admin-only, not heartbeat-revivable).
- **Failover (`promoteEvents`).** When the *current* version leaves `Connected` and a
  **lower still-`Connected`** version exists, the aggregate emits
  `VersionPromoted(defOfLower)`. Crucially this uses `highestConnectedExcluding`, which
  filters to `Connected` only — it **never** promotes a `Disconnected`/`Inactive`/`Retired`
  version. See §6 for why this is the *only* sane rollback.

---

## 3. Heartbeats & the Scheduler — what makes `Connected` true

A version is `Connected` only while its deployed infrastructure keeps sending
`Heartbeat` commands. When a version's stack is torn down, the heartbeats stop, and the
**Scheduler** (see [Scheduler component](/app/components/scheduler) /
[Heartbeat component](/app/components/heartbeat)) eventually times out the missing
heartbeats and issues `Disconnect`, flipping the version to `Disconnected`.

This is the mechanical realisation of the invariant: **`Connected` is a liveness
proxy.** A version cannot stay `Connected` if its infra is gone — it just takes until
the heartbeat-timeout window elapses for the read models to catch up.

> The timeout is not instantaneous. There is a lag (on the order of minutes) between
> "infra gone" and "status flips to `Disconnected`". Most of the surprising behaviour
> in §5–§7 lives inside that lag window.

---

## 4. The read side — two read models

### `Plugins` — current view, one row per **name**

One row per plugin name, holding the **current** version's definition flattened out,
with `status` = the current version's status. This is what kills the historical
**duplicate-menu bug**: no matter how many versions are transiently live, the name maps
to exactly one current row.

It also carries **`otherConnectedVersions: array<version>`** — the *other* versions of
the same name that are currently `Connected` (the row's own version is excluded; its
status is the `status` field). This is what lets the projection recompute "current" during
a deploy overlap; its purpose and design are covered in §5. It is empty in steady state.

The platform's component manifest (`Platform_ComponentDefinitions`) independently dedups
to **one entry per name = the highest `Connected` version**, mirroring the same
"one current" rule at the manifest layer.

### `PluginHistory` — audit view, one row per **transition**

A composite-key read model:

- **partition key** = plugin `name` (the aggregate id)
- **sort key** = `transitionKey` = `version#transitionAt#transition`

One row per lifecycle transition — the full per-version timeline, including the derived
`Superseded` and `Promoted` edges that the `Plugins` view does not represent. The
projection folds with `UpdateMultiState` and is **idempotent** (a row whose
`transitionKey` already exists is skipped), so reprojection is safe.

`PluginHistory` is a *visible admin read model* exposed through the standard
auto-generated GraphQL surface — see §8.

---

## 5. `otherConnectedVersions` — what it is and why it exists

The `Plugins` row must answer one question that the per-version events don't directly
encode: *given several versions of a name can be `Connected` at once (a deploy overlap),
which one is current?* `current` is derived as the **highest `Connected` version**, and
`VersionConnected(def)` never says *"this is now current"* — so the projection needs the
set of currently-`Connected` versions to compute it (and to recompute it identically on
replay). `otherConnectedVersions` is exactly that set, minus the row's own version.

Concretely it lets the projection, when a **lower** version (re)connects while a higher
one is current, keep the higher one current instead of naively overwriting the row with
whatever just connected. It is also what `VersionPromoted` consults for failover (§6).

Because it only ever holds versions that are *currently* `Connected`, it is **pruned** the
moment a version drops out (`VersionDisconnected` / `Deactivated` / `Retired` of a
non-current version removes it). So it is empty in steady state and holds at most the
one-or-two concurrently-live versions of a rolling deploy — never the full history.

> **It used to be `knownStatuses`** — a `dict<version → statusString>` of *every* version
> ever seen, which grew without bound and exposed raw status bookkeeping in the admin
> view. The slimmer, self-pruning `otherConnectedVersions` carries only what the
> projection actually consumes (the Connected set), so it stays bounded and reads as
> meaningful operator info ("this name has another version still live"). The full
> per-version audit trail lives in `PluginHistory`, not here.

**Write side vs read side.** This read-model field is *not* the source of truth. The
aggregate's write-side `known: dict<version → knownVersion>` still carries the full set
*with definitions* and the non-`Connected` entries — it needs them to tell a reconnect
from a new connect ([§2](#2-the-write-side--one-name-keyed-aggregate)) and to carry the
definition for promotion. The read model derives its slimmer view from the events. (If the
write side emitted the current-pointer explicitly, the read model could stop recomputing
entirely — a possible future simplification, not done here.)

---

## 6. Rollback — stepping back to a previous version

When an admin decides a newly-deployed version is misbehaving, rolling back means making
an **earlier** version current again. There is no dedicated `Rollback` command — rollback
is expressed through the existing admin commands plus the automatic promotion the
aggregate performs when the current version leaves `Connected`.

### How it works

`current` is always the **highest `Connected` version** (§2), so a lower version cannot be
current while a higher one is still `Connected`. Rolling back therefore means taking the
bad (higher) version *out* of the `Connected` set, with one command on the current version:

- **`Deactivate(badVersion)`** — suspends it (`→ Inactive`); reversible later with `Activate`.
- **`Retire(badVersion)`** — archives it (`→ Retired`); terminal.

When either command targets the current version, the aggregate automatically appends a
**`VersionPromoted`** for the next-highest version that is *still* `Connected`
(`promoteEvents` → `highestConnectedExcluding`). So a single command both removes the bad
version and steps the current pointer back.

Worked example — current is `alpha.88`, the previous `alpha.86` is still `Connected`:

```
Deactivate(alpha.88)
  ├─ VersionDeactivated(alpha.88)   // alpha.88 → Inactive, leaves the Connected set
  └─ VersionPromoted(alpha.86)      // alpha.86 = highest remaining Connected → current
```

The `Plugins` read model flips the `alpha.88` row to `Inactive`, then `VersionPromoted`
makes `alpha.86` the current row; `PluginHistory` records both transitions
(`Deactivated`, `Promoted`).

### Stepping to a lower version number is fine

"Highest version wins" is about the highest **`Connected`** version, not the highest that
ever existed. Once `alpha.88` is `Inactive`, the highest `Connected` version *is*
`alpha.86`, so promoting it doesn't violate the rule — `VersionPromoted` just records the
explicit step-down. `Activate(alpha.88)` later is the inverse: it re-enters `Connected`,
and being the higher version, supersedes `alpha.86` again.

### Do you have to wait for the new version's heartbeat to stop?

**No, if the admin actively deactivates/retires it.** `Deactivate`/`Retire` emit the
`VersionPromoted` in the *same* command, so the switch to `alpha.86` is immediate — no
heartbeat-timeout is on that path. The still-running `alpha.88` keeps heartbeating, but a
`Heartbeat` for an `Inactive`/`Retired` version is ignored (not heartbeat-revivable), so
it does not flip back.

You only wait for the timeout in the **passive** case — if, instead of issuing a command,
you just stop the new version. Then nothing changes until the Scheduler times out its
missing heartbeats and issues `Disconnect(alpha.88)`, which triggers the same
`promoteEvents` failover. That path is bounded by the heartbeat-timeout window (§3).

### The one precondition: the target must still be `Connected`

Promotion can only pick a version that is *currently* `Connected` — still deployed and
heartbeating:

- **During the deploy overlap window (§7)** the previous version is still up, so rollback
  is instant.
- **After the old stack has been torn down** the previous version is `Disconnected`, so
  `promoteEvents` finds nothing to promote: `Deactivate(alpha.88)` then leaves the plugin
  with **no current version** until something reconnects. To roll back at that point you
  must first **redeploy the previous version** (so it reconnects and is `Connected`
  again), then deactivate/retire the bad one.

---

## 7. The deploy overlap window (and how it goes wrong)

Every rolling deploy produces a window where the new version is up and heartbeating
**while the old one is still being torn down** — both `Connected` simultaneously. This is
normal, not an edge case. The framework's job in that window is to deterministically
designate **one** current version (the highest `Connected`), so menus and routing don't
duplicate.

You can observe the window directly in the admin Plugins view. Example:

| Name | Version | Other Connected Versions | Status |
|---|---|---|---|
| Ordering | `1.0.0-alpha.88` | `[]` | Connected |
| Catalog | `1.0.0-alpha.88` | `[1.0.0-alpha.86]` | Connected |

Ordering's old version has already been timed out to `Disconnected`, so it was pruned
from `otherConnectedVersions` (empty = nothing else live). Catalog is still mid-window:
`alpha.86` is still `Connected` — no `VersionDisconnected`/`Retired` for it has arrived
yet — so it lingers in the set. The displayed **row** status (`Connected`, current
`alpha.88`) is correct; the entry simply clears once the Scheduler times `alpha.86` out.

The old version leaves `Connected` via one of:

- the **Scheduler** heartbeat-timeout (`VersionDisconnected`), once the old stack stops
  heartbeating, or
- **retirement** (`VersionRetired`) — admin-initiated, or as part of supersession.

> ⚠️ **Stuck dual-`Connected`.** If both versions stay `Connected` well past the
> heartbeat-timeout window, the old version's `VersionDisconnected` / `VersionRetired`
> transition never reached the Plugin aggregate — that's a fault to investigate, not the
> normal transient. (The normal case resolves on its own when the Scheduler times the
> old version out.)

---

## 8. The admin GraphQL surface (parity with ordinary read models)

`PluginHistory`, `Plugins`, and `PlatformEventGraph` are **admin** read models. They are
exposed through the *same* spec-driven generator (`GraphQL_FragmentGenerator`) that
ordinary read models use: their query entries
(`PluginBaseFragment.queryEntries`) derive `subIdField` from each spec's `subIdConfig`
and `indexQueries` from `config.indexes`, so the generator emits — automatically and in
lockstep with the shared `QueryDbResolvers_{AppSync,GraphQL}` resolver layer:

- `single` — get by id (composite keys add the sort-key arg, e.g.
  `Platform_PluginHistoryEntry(id, transitionKey)`),
- `list` — Relay connection with server-side filter/sort,
- `<single>Items` — the per-partition timeline for composite-key read models
  (e.g. `Platform_PluginHistoryEntryItems(id, …)` = one plugin's full lifeline),
- `<single>By<Index>` — one field per `@index` GSI (added incrementally, per dashboard).

This means **no custom admin Lambda** is needed to surface a composite-key audit view:
`PluginHistory` keeps its composite key (`name` / `transitionKey`) and renders in the
AutoUI through the standard path. The AutoUI discovers the `Items` capability by
introspecting the live SDL — there is no sub-id hint on the `queryableDef`, which is
exactly how ordinary composite-key read models work too.

> Historically the admin path was hand-rolled and emitted only `single` + `list`, so
> making `PluginHistory` visible failed to deploy (`No field named
> Platform_PluginHistoryEntryItems` — the resolver layer created the field, the SDL
> never declared it). Closing that parity gap is what made the composite-key admin view
> deployable.

---

## 9. Operational gotchas

- **Transient dual-`Connected` is expected** during a deploy; *stuck* dual-`Connected`
  means the old version's `Disconnected`/`Retired` transition was never recorded (§7).
- **Heartbeat-timeout latency** is the source of most "the status is wrong" reports — the
  read model trails reality by the timeout window.
- **Stream re-enable → `EventSourceMapping` 409.** Switching a read model's QueryDb from a
  no-stream builder to a stream builder (e.g. making `PluginHistory` resolver-backed)
  re-enables the DynamoDB stream. A half-applied deploy can leave an orphaned
  `EventSourceMapping` that Pulumi doesn't track; the next `up` then 409s
  (`mapping already exists … UUID …`). Fix: delete the orphan
  (`aws lambda delete-event-source-mapping --uuid … --region …`), wait for it to finish
  deleting, redeploy. `pulumi refresh` does **not** help — it only reconciles resources
  Pulumi already tracks, and CI's deploy (`pulumi up`) path doesn't refresh anyway.
- **`otherConnectedVersions` is normally empty.** A non-empty value on a settled plugin
  (no deploy in progress) is a signal that an old version never dropped out (§7), not a
  rendering quirk.

---

## Related

- [Plugin component](/app/components/plugin) — what a plugin is and how it's composed.
- [Scheduler](/app/components/scheduler) / [Heartbeat](/app/components/heartbeat) — the
  liveness machinery behind the `Connected` invariant.
- [Runtime & Deployment Strategies](./runtime.md) — how plugin versions are deployed.
- [Messages](./messages.md) — how lifecycle commands and events are routed and serialized.
