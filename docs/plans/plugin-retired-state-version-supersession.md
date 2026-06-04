# Plugin `Retired` state — separate version-supersession from admin suspend

Scope: split the conflated `Inactive` terminal state into two distinct
states — `Inactive` (admin suspend, tier 2) and `Retired` (deploy-driven
version supersession) — with **revivable-by-own-heartbeat** semantics for
`Retired`. Touches the Plugin aggregate state machine, its read model, the
projection, and the lifecycle analysis doc. Core-only; no UI repo changes.

## Sequencing — ship this SECOND

Land [plugin-retire-hook-fifo-publish-fix.md](plugin-retire-hook-fifo-publish-fix.md)
**before** this plan. That fix (a small `fix(aws):` patch) is what makes
the deploy-time `Retire` command actually fire; until it lands, retire
never reaches the aggregate and this state-machine change has no
observable effect on a live stack. This plan is the larger
`feat(admin)!:` correctness change and depends on the fix for end-to-end
verification (the `decide`/`evolve`/projection logic is unit-testable via
GWT without it). See that plan's *Sequencing* section for the full
rationale.

## Motivation

### The conflation

Two semantically different events collapse onto the same state today:

- `Deactivate` → `Deactivated` event → `Inactive` state
  ([PluginBehavior.res:67-73, 158](../../reventless/reventless-core/src/admin/PluginBehavior.res#L67-L73))
  — an admin deliberately suspended the plugin; reversible via `Activate`.
- `Retire` → `Retired` event → `Inactive` state
  ([PluginBehavior.res:74-80, 159](../../reventless/reventless-core/src/admin/PluginBehavior.res#L74-L80))
  — a newer plugin **version** superseded this one at deploy time.

The projection merges both into one branch writing `status: Inactive`
([PluginsProjection.res:138-162](../../reventless/reventless-core/src/admin/PluginsProjection.res#L138-L162)),
so the read model cannot tell *why* a plugin is inactive. Worse,
`Inactive + Activate` is permitted
([PluginBehavior.res:104-112](../../reventless/reventless-core/src/admin/PluginBehavior.res#L104-L112)),
so an admin can "reactivate" a superseded old version whose Lambda no
longer exists — semantically wrong.

The events already carry the distinction (`Retired` vs `Deactivated`); it
is `evolve` and the projection that throw it away.

### Live-data evidence (alpha, eu-west-1, `Plugins-d4612ef`)

A scan of the live platform's Plugin read model on 2026-06-04 shows the
deploy-time retire path is **inert** in the hybrid topology — every old
version sits in `Disconnected` (timed out `by: "Scheduler"`), not the
intended `Inactive`-via-`Retired`:

```
Disconnected  Catalog@1.0.0-alpha.67   by: Scheduler   (timed out, not Retired)
Connected     Catalog@1.0.0-alpha.71   by: Heartbeat
Disconnected  Ordering@1.0.0-alpha.67  by: Scheduler
Connected     Ordering@1.0.0-alpha.71  by: Heartbeat
```

That inert-retire issue is a **separate** concern (see *Related work*),
but it surfaced the modeling smell this plan addresses, and it shows the
practical consequence: because old versions land in `Disconnected`, a
straggler `Heartbeat` (`Disconnected + Heartbeat → Reconnected`) can flap
a superseded version back to `Connected`, re-introducing the
two-versions-connected duplication on the site.

## The version-supersession axis

The existing model ([plugin-lifecycle-tiers.md](../analysis/plugin-lifecycle-tiers.md))
defines three tiers on a single "is the plugin up?" axis:

- Tier 1 `Disconnected` — transient outage; auto-recovers on heartbeat.
- Tier 2 `Inactive` — admin suspend; recovers only on admin `Activate`.
- Tier 3 decommission — removes the plugin **name** from the catalog
  (membership change, SDL re-stitch); unmodeled.

`Retire` is none of these. It is **per-version**, deploy-driven, and the
plugin (by name) stays in the platform — only the *old version row*
(`name@version`) is superseded while the new version stays `Connected`.
It changes neither catalog membership (the name persists) nor is it an
admin action. It deserves its own state.

### Recovery-axis table — the crisp distinction

The requested semantics make `Inactive` and `Retired` mirror images on
the two recovery axes:

| State | Trigger | Heartbeat revives? | Admin `Activate` revives? |
|---|---|---|---|
| `Disconnected` | liveness timeout | **yes** (→ `Reconnected`) | n/a (not suspended) |
| `Inactive` | admin `Deactivate` | no | **yes** |
| `Retired` | deploy `Retire` (superseded) | **yes** (→ `Reconnected`) | **no** (`Error(IsRetired)`) |

`Retired` is revivable **only by its own heartbeat** — i.e. an actual
redeploy/rollback of that exact `name@version` brings the identity back.
An admin cannot manually resurrect a superseded version; that would have
no running Lambda behind it. This is the inverse of `Inactive`, which an
admin controls but a heartbeat cannot revive.

## Proposed state machine

Add a `Retired(pluginDefinition)` state alongside `Inactive`.

### `decide` transitions (new/changed rows in **bold**)

| From state | Command | Result |
|---|---|---|
| `Connected` | `Retire` | **`[Retired]` + `uiDeregisterEvents`** (was `[Retired]` → Inactive) |
| `Disconnected` | `Retire` | **`[Retired]`** |
| `Inactive` | `Retire` | **`[Retired]`** (a newer version supersedes even an admin-suspended one; was idempotent `Ok([])`) |
| `Retired` | `Heartbeat` | **`[Reconnected]` + `uiRegisterEvents`** (revival) |
| `Retired` | `Retire` | **`Ok([])`** (idempotent) |
| `Retired` | `Disconnect` | **`Ok([])`** (tolerate a stray scheduled disconnect; no-op) |
| `Retired` | `ReportIncompatibility(d)` | **`[IncompatiblePluginDetected(d)]`** |
| `Retired` | `Activate` | **`Error(IsRetired)`** (admin cannot revive a superseded version) |
| `Retired` | `Connect(_)` \| `Deactivate` | **`Error(IsRetired)`** |

`Inactive` keeps tier-2 semantics unchanged: `Activate → [Activated]`,
`Heartbeat → Ok([])` ignore, `Connect`/`Disconnect`/`Deactivate →
Error(IsInactive)`.

### `evolve` transitions to add

- `Connected` + `Retired` → `Retired(def)`
- `Disconnected` + `Retired` → `Retired(def)`
- `Inactive` + `Retired` → `Retired(def)`
- `Retired` + `Reconnected` → `Connected(def)` (revival)
- `Retired` + UI-fragment events → `Retired` (no-op, mirror existing arms)
- `Retired` with any other event → `throw(InvalidEvent)` (mirror existing
  total-match style)

## File-by-file changes

### 1. `PluginSpec.res` — new error variant

[reventless/reventless-core/src/admin/PluginSpec.res:50-56](../../reventless/reventless-core/src/admin/PluginSpec.res#L50-L56)

Add `IsRetired` to the `error` variant:

```rescript
@schema
type error =
  | NotExisting
  | AlreadyConnected
  | IsDisconnected
  | IsInactive
  | IsRetired
```

No new command or event is needed — `Retire`/`Retired` already exist
([PluginSpec.res:17, 41](../../reventless/reventless-core/src/admin/PluginSpec.res#L17)).

### 2. `PluginsReadModelSpec.res` — new status value

[reventless/reventless-core/src/admin/PluginsReadModelSpec.res:3-7](../../reventless/reventless-core/src/admin/PluginsReadModelSpec.res#L3-L7)

```rescript
@schema
type status =
  | Connected
  | Disconnected
  | Inactive
  | Retired
```

Additive to the sury `@schema` variant and the GraphQL enum it backs
(`queryResult.status`, [:44](../../reventless/reventless-core/src/admin/PluginsReadModelSpec.res#L44))
— existing rows decode unchanged; new value only appears going forward.

### 3. `PluginBehavior.res` — split the terminal state

[reventless/reventless-core/src/admin/PluginBehavior.res](../../reventless/reventless-core/src/admin/PluginBehavior.res)

- Add `Retired(pluginDefinition)` to the `state` variant
  ([:5-13](../../reventless/reventless-core/src/admin/PluginBehavior.res#L5-L13)).
- In `decide`, retarget `Retire` from `Connected`/`Disconnected`/`Inactive`
  to emit `Retired` (it already does) but rely on the new `evolve` arm to
  land in `Retired` rather than `Inactive`; add the new `Retired` state arm
  per the table above.
- In `evolve`, add the `Retired` arms above; `Connected`/`Disconnected`/`Inactive`
  + `Retired` → `Retired(def)`, and `Retired` + `Reconnected` → `Connected(def)`.

Reuse the existing `uiRegisterEvents` / `uiDeregisterEvents` helpers
([:17-27](../../reventless/reventless-core/src/admin/PluginBehavior.res#L17-L27))
so revival re-registers UI fragments and retirement deregisters them —
symmetric with the `Disconnected ↔ Reconnected` pair.

### 4. `PluginsProjection.res` — split the merged branch

[reventless/reventless-core/src/admin/PluginsProjection.res:138-162](../../reventless/reventless-core/src/admin/PluginsProjection.res#L138-L162)

Split the combined `Deactivated | Retired` case:

- `Deactivated(...)` → `status: Inactive` (unchanged).
- `Retired(...)` → new branch writing `status: Retired` (same
  `UpdateWithDefault` shape, preserving `apiSchemaFragment` / `uiFragments`
  / `structure` like the other arms).

`Reconnected` already maps to `status: Connected`
([:62-112](../../reventless/reventless-core/src/admin/PluginsProjection.res#L62-L112)),
so revival from `Retired` needs no projection change.

### 5. Manifest / API filters — verify, no change expected

- `Platform_UIDefinitions` filter `contains(#status, :connected)` with
  `:connected = "Connected"`
  ([Platform_UIDefinitions_Lambda.res:37-39](../../reventless/reventless-aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res#L37-L39)):
  `"Retired"` does **not** contain `"Connected"` (case-sensitive), so
  retired versions stay filtered out — same as `Inactive`/`Disconnected`.
- The retire-hook scan uses exact `#s = :connected`
  ([Platform.res:586](../../reventless/reventless-aws/src/Platform.res#L586))
  — unaffected.
- In-memory `Platform_UIDefinitions` status filter (`Some(Connected) =>
  true | _ => false`) — `Retired` falls into `_ => false`, already correct.

Confirm both during verification; no code change anticipated.

### 6. `Platform.res` retire-hook comment

[reventless/reventless-aws/src/Platform.res:563-568](../../reventless/reventless-aws/src/Platform.res#L563-L568)

The comment states the aggregate "evolves to Inactive and the projection
writes status: Inactive". Update to `Retired` / `status: Retired`.

### 7. `plugin-lifecycle-tiers.md` — document the supersession axis

[docs/analysis/plugin-lifecycle-tiers.md](../analysis/plugin-lifecycle-tiers.md)

Add a section distinguishing **version supersession** (`Retired`,
per-version, deploy-driven, heartbeat-revivable) from tier 2 admin suspend
(`Inactive`, per-version, admin-driven, admin-revivable) and tier 3
decommission (per-name, membership change). Add `Retired` to the
tier × surface matrix ([:91-105](../analysis/plugin-lifecycle-tiers.md#L91-L105))
and the recovery-axis table from this plan. Per repo convention, the
analysis doc must track the model change.

### 8. Tests

- `PluginBehavior_GWT.res` — add cases: `Connected/Disconnected/Inactive +
  Retire → Retired`; `Retired + Heartbeat → Reconnected → Connected`
  (revival); `Retired + Activate → Error(IsRetired)`; `Retired + Retire →
  Ok([])` idempotent. Adjust any existing case asserting `Retire → Inactive`.
- `PluginsProjection_GWT.res` — assert `Retired` event writes
  `status: Retired` (was `Inactive`); assert revival via `Reconnected`
  writes `status: Connected`.

## The straggler-flap tradeoff (explicitly accepted)

Revivable-by-own-heartbeat means a **straggler `Heartbeat`** for a
just-retired version (one already enqueued in the Plugin CommandTopic FIFO
before the heartbeat Lambda was updated to the new version) can flip it
`Retired → Reconnected → Connected`, briefly re-introducing two connected
versions. This is the same transient duplication that exists today during
the deploy-overlap window, now reachable for the retire path too.

We accept it because:

- It self-heals — the revived old version receives no further heartbeats
  (the Lambda now emits the new version), so its disconnect schedule fires
  in ~7 min → `Disconnected`.
- The aggregate cannot know about sibling versions (a single `name@version`
  identity has no cross-aggregate view), so a "don't revive if a newer
  version is Connected" guard cannot live in `decide`.
- The alternative — making `Retired` ignore heartbeats — would break
  rollback-to-same-version, which is the whole reason for choosing the
  revivable variant.

Optional hardening (out of scope, note for later): purge/short-circuit the
old version's pending CommandTopic messages at retire time, or move a
"superseded by newer Connected version" guard to the manifest/projection
layer (which *can* see sibling versions) rather than the aggregate.

## Verification

1. `pnpm exec rescript build` clean — zero warnings
   (`npm run build 2>&1 | grep -E "Warning|warning|error|Error"`).
2. `PluginBehavior_GWT` and `PluginsProjection_GWT` pass with the new
   transitions.
3. In-memory smoke: connect a plugin, fire `Retire` → read model shows
   `status: Retired` and the plugin drops out of `Platform_UIDefinitions`;
   fire a fresh `Heartbeat` for that version → it revives to `Connected`
   and reappears; fire `Activate` on a `Retired` plugin → `Error(IsRetired)`.
4. Confirm `Platform_UIDefinitions` (AWS filter `contains(status,
   "Connected")` and the in-memory equivalent) excludes `Retired` rows.

## Related work (not in this plan)

- **Inert retire hook in hybrid topology.** `publishRetireForOlderPluginVersions`
  ([Platform.res:575-646](../../reventless/reventless-aws/src/Platform.res#L575-L646),
  called at [:1014-1028](../../reventless/reventless-aws/src/Platform.res#L1014-L1028))
  never takes effect on the live `online-shop-hybrid` stack — old versions
  time out to `Disconnected` instead of being `Retired`. Likely the gating
  `(Some(rmTableName), Some(cmdTopicUrl)) if version != ""` resolves to
  `None` when plugins deploy as separate Pulumi stacks from the platform,
  or a silently-swallowed IAM denial (`dynamodb:Scan` / `sqs:SendMessage`).
  This plan makes the *destination* state correct; a companion plan should
  make the retire actually fire. The two compound: only once retire fires
  **and** lands plugins in a terminal `Retired` state does the deploy
  overlap close to a clean single-version manifest.

## References

- [PluginSpec.res](../../reventless/reventless-core/src/admin/PluginSpec.res) — command/event/error types.
- [PluginBehavior.res](../../reventless/reventless-core/src/admin/PluginBehavior.res) — `decide`/`evolve` state machine.
- [PluginsReadModelSpec.res](../../reventless/reventless-core/src/admin/PluginsReadModelSpec.res) — `status` enum + read-model state.
- [PluginsProjection.res](../../reventless/reventless-core/src/admin/PluginsProjection.res) — event → status mapping.
- [Platform_UIDefinitions_Lambda.res](../../reventless/reventless-aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res) — AWS manifest status filter.
- [Platform.res:575-646](../../reventless/reventless-aws/src/Platform.res#L575-L646) — deploy-time retire hook.
- [plugin-lifecycle-tiers.md](../analysis/plugin-lifecycle-tiers.md) — three-tier lifecycle model this plan extends.
- [aws-plugin-activate-deactivate-resolver.md](aws-plugin-activate-deactivate-resolver.md) — tier-2 admin workstream (sibling lifecycle work).
</content>
</invoke>
