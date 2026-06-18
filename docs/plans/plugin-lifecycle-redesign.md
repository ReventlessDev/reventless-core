# Plan: Plugin Lifecycle Redesign + Folder Consolidation

**Date:** 2026-06-17

**Analysis:** [docs/analysis/plugin-lifecycle-redesign.md](../analysis/plugin-lifecycle-redesign.md)

---

## Progress (2026-06-18)

| Step | Status | Commit / notes |
|---|---|---|
| Part 1 — folder consolidation into `src/plugin/` | ✅ done | `92deffb` |
| moduleUrl specifiers via `@@reventless.spec` (move-safety) | ✅ done | `5bc47cb` — not in the original plan; surfaced as a Part 1 regression |
| Part 2 core — name-keyed aggregate + current view + EP translation | ✅ done | `c6720d0` — GWT-verified; core 418 + local 416 tests pass |
| Part 2 — delete deploy-time retire hook | ✅ done | `3322841` — incl. `pluginAggrCmdTopicUrl` export/stack-ref removal |
| **Bug fix (duplicate menu) — structurally resolved** | ✅ | one row per name + write-side supersession + hook gone |
| Part 2 — `PluginHistory` view (core + AWS) | ✅ done | core spec/projection + 8 GWT tests; AWS `ReadModel_Builder_NoResolver_Stream` (composite-key, internal, no resolver). Local population landed with F1 refactor below |
| Part 2 — F1 local Connect-flow refactor (decision ii) | ✅ done | local now routes through `LocalPluginAggregate`: real `PluginsReadModel` + `PluginHistoryReadModel` (NoResolver) wired into both `Admin.construct` sites; `seedPluginQueryDb` direct-write → synthetic `Connect(def)` dispatch; hand-written Activate/Deactivate resolvers → aggregate-dispatched `Activate`/`Deactivate`/`Retire`; `onPluginStatusChange`/`onUIFragmentChange` relocated to a Plugin-event-topic bus subscription. Verified at runtime (Platform_Plugins read; Deactivate→Inactive→Activate→Connected→Retire; PluginHistory timeline folds). core 418 + local 424 green |
| Part 2 — AWS version-arg admin path | ⬜ verify | `Activate`/`Deactivate`/`Retire(version)` mutations (deploy-path, not test-covered) |
| Part 3 — zero-downtime synthetic heartbeat + deploy contract | ⬜ todo | |

**Decisions locked in during implementation:**
- **Version carried by EP-boundary translation (Approach 1)** — §2.2.
- **`Plugin_Builder` is NOT re-keyed** — PLUGIN_ID stays `name@version` (transport);
  the re-key is purely at the admin aggregate via the EP mapping. (The plan's
  earlier "Plugin_Builder id → name" step is therefore void.)
- **Current view uses a compact `knownStatuses` map** (not a full fat state) to
  recompute current on drop-out / rollback; `Superseded` is *derived* (Connected
  && ≠ current), not an aggregate status — §2.4.
- **Manual `Retire` = Option A** (API mutation + un-retire via `Activate`) — §2.5.
- Part 2 landed as a **green checkpoint** (core) + follow-ups, since core + local
  + GWT tests are too coupled for independent green sub-commits.

---

## Goal

Two intertwined deliverables, sequenced so each commits independently:

1. **Consolidate all plugin-related files into a dedicated folder** under each
   package's `src/` (and `tests/`). Today they are scattered across
   `src/admin/`, `src/components/Plugin/`, and several `reventless-aws`
   subdirectories. This is a pure reorganisation — no behaviour change.
2. **Redesign the plugin lifecycle around a single name-keyed aggregate.** One
   component owns a plugin name's whole lifecycle — connect / heartbeat /
   supersede / disconnect / retire — deciding synchronously and emitting one
   ordered, intentful event stream. The name-keyed `Plugins` "current" view and
   the rich `PluginHistory` view are faithful folds of that stream, "exactly one
   current version" is an enforced invariant, and the deploy-time RM-scan retire
   hook is deleted. This kills the duplicate-menu bug at its source.
3. **Guarantee near-zero-downtime version handover** (mandatory): fire an
   immediate synthetic heartbeat at deploy so a new version connects in seconds,
   and document the expand/contract deploy contract for schema/GSI-changing
   deploys. Analysis §12.

The analysis is the design record; this plan is the implementation sequence.

---

## Why the folder move is low-risk (read first)

ReScript has a **flat module namespace per package**, and both `reventless-core`
and `reventless-aws` declare `sources: [{dir: "src", subdirs: true}, {dir:
"tests", subdirs: true}]`. Subdirectories are recursively compiled and modules
are referenced by bare name regardless of folder. **Therefore moving a `.res`
file between folders under `src/` does NOT break any `open Foo` / `Foo.bar`
reference** — folders are organisational only.

Consequences for the plan:
- No `open`/module-reference edits are needed for the move itself.
- The only real risks are (a) **stem-name collisions** — already-illegal today,
  so a move surfaces none that didn't exist — and (b) **tracked `.res.mjs`
  outputs** moving with their sources (in-source build; see CLAUDE.md
  `.res.mjs` tracking). Use `git mv` for the `.res`, build, then stage the
  regenerated `.res.mjs` at the new path and remove the stale one.
- Do the move as its **own commit, before** any lifecycle change, so the
  redesign diff is readable.

---

## Part 1 — Folder consolidation

### 1.1 Target layout (`reventless-core/src/`)

Create `src/plugin/` and move the plugin component + admin-lifecycle files into
sub-areas. Proposed grouping (flat namespace means grouping is cosmetic — pick
for readability):

```
src/plugin/
  component/        Plugin.res, Plugin_Builder.res, Plugin_Callback.res,
                    Plugin_BuiltHook.res, Plugin_Helpers.res,
                    Plugin_ResolverError.res, Plugin_Structure.res,
                    Plugin_SubscriptionSchema.res, SchemaWalker.res
  lifecycle/        PluginBehavior.res, PluginSpec.res,
                    PluginsReadModelSpec.res, PluginsProjection.res
  connect/          PluginConnectExtension_Builder.res,
                    PluginConnectExtension_Mapping.res,
                    PluginExtensionPoint_Builder.res,
                    PluginExtensionPoint_Plugin.res,
                    PluginExtensionPointRuntime_Builder.res
  api/              PluginBaseFragment.res, AdminApi.res
```

**Stays in `src/admin/`** (platform-admin concerns that are not plugin
lifecycle): `Platform_Admin.res`, `Platform_Admin_Structure.res`,
`Platform_EventGraph*`, `Platform_ComponentDefinitionsApi.res`,
`Platform_CrossPluginEdges.res`, `Platform_UIFragmentsApi.res`,
`UIFragmentRegistry*`.

> **Decision needed (§Open Q1):** whether `Platform_Admin.res` and the
> UIFragmentRegistry pair move under `src/plugin/admin/` too, or stay in
> `src/admin/`. Default: keep them in `src/admin/` — they are the *platform*
> admin aggregate, not plugin-lifecycle per se. The Plugin aggregate lives in
> `Platform_Admin` today (analysis §A.1, `Platform_Admin.res:261`), so confirm
> the boundary before splitting.

### 1.2 Target layout (`reventless-aws/src/`)

```
src/plugin/
  runtime/   adapter/Runtime/PluginRuntime_Builder.res,
             adapter/Runtime/PluginExtensionPointRuntime_Builder.res,
             util/PluginRuntimeOperations.res
  heartbeat/ adapter/Heartbeat/HeartbeatRunner.res,
             adapter/Heartbeat/HeartbeatRunner_CloudWatchEvents.res
  cloner/    adapter/Cloner/ClonerRunner*.res
  stack/     Plugin_Stack.res, core/Plugin_ExtensionPoint_Builder.res
```

`Platform.res` stays put (it is the AWS platform entry, not a plugin file) but
loses `publishRetireForOlderPluginVersions` in the lifecycle redesign (Part 2).

### 1.3 Tests

Move the matching test files alongside (folders are cosmetic here too):
- `reventless-core/tests/plugin/` — already exists (`PluginStructureTest.res`,
  `PluginVersionTest.res`); keep.
- `reventless-core/tests/admin/Platform_CrossPluginEdgesTest.res` — stays
  (cross-plugin edges remain an admin concern).
- `reventless-local/tests/plugin/PluginBehavior_GWT.res`,
  `PluginsProjection_GWT.res` — keep in place; they reference modules by bare
  name and are unaffected by the source move.

### 1.4 Procedure (per file)

1. `git mv src/<old>/Foo.res src/plugin/<area>/Foo.res`.
2. After all moves, `pnpm run build` from the package dir; verify zero warnings
   (`pnpm run build 2>&1 | grep -E "Warning|warning|error|Error"`).
3. Stage regenerated in-source `.res.mjs` at new paths; `git rm` stale outputs
   left at old paths (`git ls-files --deleted` then `git add`/checkout as
   needed — see MEMORY: rescript clean wipes tracked `.res.mjs`).
4. Commit: `refactor(core): consolidate plugin files under src/plugin/` (no
   behaviour change → `refactor:`, not `feat:`/`fix:`).

**Verification:** full `pnpm run build` + `pnpm test` green, zero warnings.
Confirm no stem collisions reported by the compiler.

---

## Part 2 — The plugin lifecycle redesign

One component owns a plugin name's whole lifecycle. The plugin **name** becomes
the aggregate (re-keyed from `name@version`), it decides supersession
synchronously, and it emits one ordered, intentful stream. Both read views fold
that stream; the deploy-time retire hook disappears. Analysis §5.2, §6, §8.

### 2.1 Re-key the admin Plugin aggregate `name@version → name` ✅

- The **admin Plugin aggregate** instance id becomes the bare plugin **name**.
  This is achieved entirely at the **EP-mapping boundary** (§2.2): the aggregate
  is keyed by whatever id the incoming command carries, and the EP now sends
  `Plugin.name(id)`. **`Plugin.makeId` / `Plugin_Builder` are unchanged** — the
  plugin *component* identity and `PLUGIN_ID` stay `name@version` (the transport
  id), per Approach 1. (Supersedes the earlier "`Plugin_Builder.res:127` becomes
  name" wording.)
- Aggregate state: `{ current, known: dict<version, {definition, status}> }`
  (no `lastHeartbeatAt` — liveness is scheduler-driven, not time-in-aggregate).
  `Retired` is a **per-version sub-state inside `known`**, not a terminal state
  of the whole aggregate (analysis §6.2.6) — the name keeps accepting and
  promoting new versions while old versions sit `Retired`.
- **Wipe** the Plugin EventLog + Plugins QueryDb on deploy (plugins re-register
  via heartbeat; migration is not a concern — analysis §8, MEMORY: wipe alpha
  over migration).

### 2.2 Carry the version by translating at the EP boundary (Approach 1)

**Resolved (§9.8):** the version is carried by *translating at the
ExtensionPoint→Plugin mapping boundary*, **not** by changing the heartbeat
transport. The heartbeat Lambda, `PLUGIN_ID` env (`name@version`),
`HeartbeatEntryPoint.mjs`, the EP `Heartbeat` command and its schema are all
**unchanged**. Only `PluginExtensionPoint_Plugin`'s mapping converts the EP-level
`name@version` id into a **`name`** id for the Plugin (Delegate) aggregate, with
`version` placed into the Delegate command:
- `mapIncomingCommand`: `Heartbeat` → `PublishCommand(name(id), Delegate.Heartbeat(version(id)))`;
  `DisconnectPlugin` → `Disconnect(version(id))`; `ConnectPlugin(def)` carries the
  version inside `def` already.
- `mapOutgoingEvent`: Plugin events route back out keyed by `name` (the EP keeps
  its own per-version transport id for scheduling).

**Liveness stays scheduler-driven.** The EP keeps its per-version
`CreateDisconnectSchedule` (`PluginExtensionPoint_Plugin.res:143`); when a
version stops heartbeating, the schedule fires `Disconnect(version)` to the
name-keyed aggregate. **The aggregate never reads wall-clock time** — it decides
purely from event-driven status in `known`, preserving deterministic replay.

Decision logic in the name aggregate (state `{current, known: dict<version,
{definition, status}>}`):
- `Heartbeat(V)` for a not-yet-`Connected` version → emit `VersionDetected(V)`;
  the **existing `ConnectPlugin` handshake** then delivers the (possibly-changed)
  definition (analysis §2.2), replying `Connect(V, def)` → `VersionConnected(V,
  def)`; if `compareVersions(V, current) > 0` also `VersionSuperseded(prev → V)`,
  `current := V`.
- `Heartbeat(V == a Connected version)` → keep-alive, no event.
- `Heartbeat` from a stale lower version → ignored (the EP still tracks its
  liveness; the aggregate emits nothing).
- `Disconnect(V)` (from the EP timeout) → mark V `Disconnected` in `known`; if V
  was `current`, emit `VersionPromoted(W)` for the highest still-`Connected` W in
  `known` (rollback), reusing its stored definition.
- stray heartbeat for a `Retired` version → ignored (the deliberate contrast
  with `Disconnected`, analysis §6.2.6).
- `compareVersions` already exists (`Plugin.res:73-100`).

This meets every goal of the redesign (name-keyed owner, write-side supersession,
single-current invariant, faithful history) with the transport and liveness
mechanisms unchanged — the smaller, ES-cleaner of the two mechanisms evaluated.

### 2.3 The lifecycle states — rename, don't drop (analysis §6.2.1)

- The automatic deploy-supersession concept (today overloaded onto `Retired`)
  becomes **`Superseded`**.
- **`Retired`** is repurposed for a manual admin "archive this exact version" act.
- Keep `Disconnected` (auto heartbeat timeout, still listed) and `Inactive`
  (admin suspend) distinct.
- This touches every reader of `status`: manifest filters, `forwardCommand`,
  `AdminApi.res`, admin UI, `Platform_EventGraphProjection`. Audit all (Open Q —
  analysis §9.5). The manifest shows only the **current `Connected`** version;
  the admin/history view shows `Disconnected` / `Superseded` too.

### 2.4 The two read views fold the stream (analysis §6)

Stream events: `VersionDetected` · `VersionConnected` · `VersionSuperseded(from,
to, at)` · `VersionPromoted` · `Disconnected` · `Retired`.

- **`Plugins` — current view** (§6.1): keyed by plugin **name**, one row per
  name, holding the current connected version's `definition` / `structure` /
  `uiFragments` / `apiSchemaFragment` / `version` / `status`. **This is the
  duplicate-menu fix** — the manifest can only ever emit one entry per plugin.
- **`PluginHistory` — rich audit view** (§6.2): partition `name`, sort
  `version#transitionAt` timeline (+ optional `name`+`version` inventory).
  Internal visibility `@@reventless.visibility(Internal)` (hidden from the AutoUI
  manifest). Naming: `PluginHistory` vs plural-convention `PluginVersions` — Open
  Q (analysis §9.4).
- Both are **ReadModels** (the idiomatic projection for an aggregate). Confirm
  the projection model can carry the per-name fat state needed and converges
  under out-of-order events — Open Q (analysis §9.1).

### 2.5 Manual admin `Retire` — wired fully (Option A, resolved §9.7)

- `Retire(version)` is **API-exposed** (drop `@noApi`) → auto-derived
  `Plugin_Retire` admin mutation (same path as `Plugin_Activate`/`Deactivate`,
  via `Plugin_Helpers.registerAdminAggregateMutations`). Admin-authz gated.
- **Un-retire pairs with it:** `Activate(version)` on a `Retired` version is
  allowed (emits `VersionActivated`) instead of `Error(IsRetired)` — closes the
  brick risk (a retired exact version is re-admittable; a *new* version always
  connects anyway, §6.2.6).
- Admin `PluginHistory` view surfaces a Retire action per non-current version.

### 2.6 Repoint consumers and delete the retire hook

- Repoint manifest queries (`Platform_ComponentDefinitions`,
  `Platform_UIFragments`) and runtime routing `forwardCommand`
  (`PluginExtensionPoint_Plugin.res:28-44`) at the name-keyed current view. The
  dedup from `7a21ca304` becomes defence-in-depth, no longer load-bearing.
- **Delete** `publishRetireForOlderPluginVersions` (`Platform.res:577-663`) and
  its call site (`Platform.res:1055`), plus its plumbing: the `StackReference`
  reads of the RM table name / command-topic URL (`Platform.res:833-844`), the
  gate, and the `pluginAggrCmdTopicUrl` export. **Audit** whether the
  `pluginRmTableName` export is still needed for the runtime status gate.

### 2.7 AWS admin path (version-arg commands)

The re-key makes the aggregate id `name`, so admin commands carry `version`:
- `Activate`/`Deactivate`/`Retire` mutation inputs gain a `version` field
  (auto-derived from the command schema); resolver routes to instance `name`.
- The **resolver status gate** (`AggregateEntryPoint.mjs::checkPluginStatus`,
  scans Plugin RM by status) and the `PluginStatus` enum + `onPluginStatusChange`
  subscription in `AdminApi` gain the `Superseded` status.
- MCP tools `Plugin_Activate`/`Deactivate` (+ new `Plugin_Retire`) gain the
  `version` arg.

### 2.8 Local adapter — route through the aggregate (F1, decision (ii))

Replace the local **direct-write bypass** so local mirrors AWS:
- Subscribe `PluginsProjection` + the new `PluginHistory` projection to the
  `PluginAggrEventTopic`; the projection builds the Plugin QueryDb.
- `seedPluginQueryDb` (`reventless-local/src/Platform.res:933`) dispatches a
  synthetic `Connect(pluginDefinition)` per plugin through `LocalPluginAggregate`
  instead of writing the row directly (resolve the Output chain before tests run
  — the DCB-E2E async-handler-registration pattern).
- **Delete** the hand-written `Plugin_Activate`/`Deactivate` resolvers
  (`Platform.res:1681-1687`); the auto-derived `Activate`/`Deactivate`/`Retire`
  mutations dispatch real commands through the aggregate; the projection updates
  the read side. Preserve `onPluginStatusChange` / `onUIFragmentChange` emission.

### 2.9 Tests + verification

- GWT coverage for: detect→connect arc, supersession on higher-version connect,
  rollback on current-timeout, stray-heartbeat-from-`Retired` ignored,
  new-version-after-retire connects, manual `Retire` + un-retire via `Activate`
  (analysis §6.2.6, §7).
- Update `PluginsProjection_GWT.res` for the name-keyed fold; local E2E now
  exercises the aggregate (decision (ii)).
- Verify the enforced invariant "exactly one current"; history is a faithful
  fold (zero inference). Build green, zero warnings.

### 2.10 Staged commits — actual

See the **Progress** table at the top for live status. As built (core + local +
GWT tests proved too coupled for independent green sub-commits, so the core
landed as one checkpoint):

1. ✅ core aggregate + current view + EP translation + GWT tests (`c6720d0`).
2. ✅ delete retire hook (`3322841`).
3. ✅ `PluginHistory` view (§2.4) — core spec/projection/GWT + AWS read model
   (`ReadModel_Builder_NoResolver_Stream`, composite-key timeline, internal, no
   AppSync resolver — scan-consumed like UIFragmentRegistry). Local QueryDb
   population deferred to step 4 (it routes through the aggregate, feeding both
   `PluginsProjection` and `PluginHistoryProjection` — no interim direct-write).
4. ✅ local F1 refactor (§2.8) — local routes through `LocalPluginAggregate`;
   real `PluginsReadModel` + `PluginHistoryReadModel` projections own the QueryDb
   stores; synthetic `Connect(def)` seed; aggregate-dispatched admin lifecycle
   mutations; subscription emission relocated to a bus subscription. Runtime-
   verified end-to-end. (Local `PluginHistory` QueryDb is populated here.)
5. ⬜ AWS version-arg admin-path verification (§2.7).

---

## Part 3 — Zero-downtime handover (mandatory; analysis §12)

The lifecycle handover is already continuous at the manifest layer (v1 stays
current until v2's connect handshake completes — analysis §12.2). Two gaps
remain; both are closed here.

### 3.1 Deploy-time synthetic heartbeat (closes handover lag)

- At the **end of `deployPlugin`** (`reventless-aws/src/Platform.res`), publish
  **one synthetic heartbeat** for the just-deployed plugin so the new version
  runs its connect handshake in seconds rather than after a full heartbeat
  interval. This publishes a *heartbeat* (not an RM-read-driven command),
  consistent with the redesign's goals (analysis §12.3.1).
- It must route through the same heartbeat path the runtime uses (Part 2 routes
  heartbeats to the `name` id with `version` in payload), so the synthetic tick
  carries the deployed version.
- Verify: after deploy, the new version reaches `Connected` without waiting for
  the CloudWatch heartbeat rule's first natural tick; the current view flips
  v1 → v2 within seconds.

### 3.2 Fast rollback (closes rollback lag)

- Keep the previous version's lifecycle row revivable so a rollback redeploy
  flips "current" back. This is the aggregate's "recompute highest live
  connected on disconnect / re-promote on reconnect" rule (Part 2.2): if v2
  disconnects, v1 — if still or again connected — is re-promoted. Confirm a
  rollback redeploy of v1 re-promotes v1 on its synthetic heartbeat.

### 3.3 Expand/contract deploy contract (schema/GSI-changing deploys)

- Document — as a deploy contract in `docs/guides/lambda-deployment.md` (or the
  live-updates guide) — that **schema/GSI-changing** deploys must sequence the
  new index/schema live *before* the new code depends on it (expand/contract).
  This is the one class the framework cannot fully auto-guarantee (analysis
  §12.3.2, §12.4).

**Verification:** a no-schema-change version bump deploys with no observable
manifest gap and no duplicate entries; rollback re-promotes the prior version on
its synthetic heartbeat.

**Commit:** `feat(aws): deploy-time synthetic heartbeat for zero-downtime plugin handover`.

---

## Sequencing & commits

1. **`refactor:` folder consolidation** (Part 1) — no behaviour change, lands first.
2. **`feat:` lifecycle redesign** (Part 2) — the name-keyed aggregate, both read
   views, retire-hook deletion; fixes the duplicate-menu bug.
3. **`feat:` zero-downtime handover** (Part 3) — mandatory; depends on Part 2's
   `name`-keyed heartbeat routing.

Each step: full build (zero warnings), `pnpm test` green, before committing.
Follow MEMORY workflow: show commit message and get approval; do not push.

---

## Open questions (from analysis §9 + this plan)

1. **Folder boundary:** do `Platform_Admin.res` / `UIFragmentRegistry*` move
   under `src/plugin/` or stay in `src/admin/`? (Default: stay.)
2. **Projection fat-state map** for "highest connected" — confirm ReadModel
   supports the per-name `{version → status}` map and converges under
   out-of-order events (§9.1).
3. **Inventory lingering-`Connected` rows** depend on heartbeat timeout; accept
   or add lightweight cleanup (§9.2).
4. **History naming:** `PluginHistory` vs `PluginVersions` (§9.4).
5. **State rename audit** — every `status` reader wired for auto `Superseded` vs
   manual `Retired` (§9.5).
6. ~~**Manual `Retire` UX & authority** (§9.7).~~ **Resolved: Option A** — wire
   `Retire(version)` as an admin-authz'd API mutation (auto-derived, like
   Activate/Deactivate), surfaced in the `PluginHistory` view; un-retire =
   `Activate` on a `Retired` version. See §2.5.
7. ~~**Detection→connect arc routing** to a `name`-keyed instance (§9.8).~~
   **Resolved:** translate at the EP boundary (§2.2, Approach 1) — the EP keeps
   its `name@version` transport id and per-version liveness; the mapping converts
   to a `name` id with `version` in the Delegate command.
8. **Whole-name decommission** — out of scope; default no (§9.10).
9. **Cross-*name* invariants** (EP-name uniqueness, dependency sets — Appendix A)
   are out of scope. If they ever become hard requirements, the aggregate would
   be reworked into an admin-side DCB slice tagged `pluginName` /
   `extensionPointName` (§9.9) — not planned now.
