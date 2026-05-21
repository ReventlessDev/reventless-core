# Plugin retire-via-event flow

## Background

`reventless-aws/src/Platform.res:550` defines `retireOlderPluginVersions`, a deploy-time hook that scans the Plugin RM table for older versions of the deploying plugin and writes `status: "Inactive"` directly to DynamoDB. This bypasses the EventLog → projection flow that is otherwise the framework's single source of truth.

The shortcut produced a concrete failure in the alpha environment: `Ordering@1.0.0-alpha.52` ended up with RM `status: Inactive` while the Plugin aggregate's replayed state was `Connected`. The UI showed "Inactive", and clicking Activate returned `AlreadyConnected` from the aggregate.

Root cause was a chain of three problems:

1. **Version source mismatch** — `examples/online-shop-hybrid/ordering-aws/src/Main.res` calls `Platform.deployPlugin(~version=Reventless.PackageVersion.fromCaller(), …)`. `fromCaller()` walks the V8 stack to the first non-framework frame, which lands in `ordering-aws/`, so it reads `ordering-aws/package.json` → `1.0.0-alpha.64`. But the Plugin component, built via `Plugin.Make(Platform)` inside `ordering/src/Plugin.res`, runs its own `fromCaller()` from a frame that lands in `ordering/` → reads `ordering/package.json` → `1.0.0-alpha.52`. The plugin runtime advertises itself as `Ordering@1.0.0-alpha.52`, but retire was told the deploy version is `1.0.0-alpha.64`. The filter `ver !== version` then matched the just-Connected current version row and "retired" it.
2. **`contains()` filter too broad** — the scan filter `#n = :n AND contains(#s, :connected)` substring-matches `"Disconnected"` too. Latent issue (not the cause this time, but tightens scope).
3. **Direct DynamoDB write** — even if the version comparison were correct, retiring out-of-band leaves the EventLog and the read model out of sync. The retire wrote `status` but not `statusChange`, so the row's `statusChange.at` still pointed to the `Connected` event's timestamp; aggregate replay still resolved to `Connected`.

The live `Ordering@1.0.0-alpha.52` row was patched by manual `UpdateItem` (`status: Connected`, `statusChange.by: manual-patch`, `at: 2026-05-21T07:30:00Z`) to unblock the UI ahead of the source fixes.

## Goals

1. Pass the correct plugin version into the retire flow.
2. Replace the direct DynamoDB write with a command published to the Plugin aggregate; the resulting event projects through the normal path.
3. Tighten the scan filter to exact-status match.
4. Cover the Plugin aggregate and `Plugins` read model with GWT tests so future drift gets caught.

Per workflow rule "Wipe alpha EventLog rather than ship event-replay migration code", the existing `PluginAggrEventLog` rows will be wiped after deploy. No in-place migration code is needed for the new event variant.

## Approach

### Domain change — add `Retire` / `Retired`

`PluginSpec.command` gains `Retire` (`@noApi`, payload-less). `PluginSpec.event` gains `Retired(pluginDefinition)`. Behaviour rules:

- `Connected(_) | Disconnected(_) + Retire → Retired(pluginDefinition)`, state evolves to `Inactive`.
- `Inactive + Retire → Ok([])` (idempotent; already retired).
- `NotConnected | Detected + Retire → Error(NotExisting)`.

Projection: `Retired → status: Inactive` (`statusChange.by` carries the meta from the retire command, typically `"deploy:<new-version>"`). EventGraph projection: `Retired → Delete(id)` (mirrors `Deactivated`). PluginExtensionPoint mapping: emit `PluginRetired(pluginDef)` outbound event and call `DoDisconnectPlugin` to tear down subscriptions and API stitching for the retired version. PluginConnectExtension mapping: include `Retired` alongside `Deactivated/Disconnected` peer-handling.

### Retire flow — publish a command, not a row update

`Platform.retireOlderPluginVersions` is replaced by `publishRetireForOlderPluginVersions`:

1. Resolve the Plugin aggregate's CommandTopic SQS URL from the platform stack reference (alongside the existing RM table reference).
2. Scan the Plugin RM with the same filter, but exact match `#s = :connected` (no `Disconnected` substring matches).
3. For each older Connected row, publish a `Retire` command keyed by the row's `id` to the CommandTopic queue, with meta `{user: "deploy:<new-version>", service: "Platform"}`. Idempotent on the aggregate side (Retire on Inactive returns `Ok([])`).
4. Logging unchanged, errors stay best-effort.

The aggregate processes the Retire commands asynchronously after deploy. The projection writes `status: Inactive` with `statusChange.by: "deploy:<new-version>"`, mirroring user-driven flows.

### Version source mismatch

The `~version` arg on `deployPlugin` and the `version` baked into `pluginDefinition` via `Plugin_Builder.make` must agree. The cleanest fix is to remove the caller-side `~version` arg entirely: the Plugin component already knows its version (via its own `fromCaller()` call inside `Plugin_Builder`). `deployPlugin` reads the version from `pluginComponent.outputs.version` (a `Pulumi.Output.t<string>`) and uses that for retire wiring.

This makes the `*-aws/Main.res` wrapper a one-call site and removes the brittle "two `fromCaller()`s must return the same package.json" coupling. Codegen template in `reventless-spec/src/generator/Codegen.res:441` updated accordingly.

## Plan

- [x] Step 0 — Patch live `Ordering@1.0.0-alpha.52` row in `Plugin-b3e394e` (`status: Connected`, `statusChange.by: manual-patch`) to unblock the UI ahead of source fixes.
- [x] Step 1 — Add `Retire`/`Retired` to `PluginSpec`, behavior decide/evolve, `PluginsProjection`, `Platform_EventGraphProjection`, `PluginExtensionPoint_Plugin.mapOutgoingEvent` (publishes `PluginRetired` + calls `DoDisconnectPlugin`), and `PluginExtensionPointSpec.event` (`PluginRetired` variant). `PluginConnectExtension_Mapping` uses a catchall so no change.
- [x] Step 2 — Hook signature on `Plugin_Helpers.preResolversSchemaHook` gains `~version`. `Plugin_Builder` passes the version it computed via `Reventless.PackageVersion.fromCaller()` (called from the plugin's own module — the right caller). `deployPlugin` no longer takes `~version`; removed `currentDeployVersion` ref. Codegen template (`Codegen.res:441`) and the two `examples/online-shop-hybrid/*-aws/src/Main.res` files updated. Infra `Platform` module type and `reventless-in-memory/src/Platform.res` updated to match.
- [x] Step 3 — `retireOlderPluginVersions` → `publishRetireForOlderPluginVersions` in `reventless-aws/src/Platform.res`. Filter tightened to exact match `#s = :connected`. Resolves `pluginAggrCmdTopicUrl` from the platform stack reference; publishes a Retire command envelope to that FIFO SQS queue per stale row (uses `Util_SQS_Runtime.safeGroupId(id)`). Platform exports the URL via `admin.aggregatesOutputs->Dict.get("Plugin")`.
- [x] Step 4 — GWT coverage extended in `reventless-in-memory/tests/plugin/` (the existing home for `Behavior_GWT.MakeFromAggregate(PluginSpec, PluginBehavior)` tests — `reventless-core` can't depend on `reventless-gwt` without a cycle). Files renamed for consistency: `PluginFixtures.res` → `Plugin_Fixtures.res` (PPX-style suffix); `PluginBehaviorTest.res` → `PluginBehavior_GWT.res`; `PluginsProjectionTest.res` → `PluginsProjection_GWT.res`; `UIFragmentRegistryProjectionTest.res` → `UIFragmentRegistryProjection_GWT.res`. Coverage added: `Retire` on every state (Connected, Disconnected, Inactive idempotent, Retired idempotent, Detected no-op, NotConnected → NotExisting; UI fragment deregistration on Connected only); `Retired` projection branch (Connected/Disconnected/new row → Inactive); exhaustive `NotConnected → NotExisting` negative coverage; `ReportIncompatibility` across Detected/Connected/Disconnected/Inactive; `IncompatiblePluginDetected` projection observation. Jest `testMatch` in root `jest.config.js` and `reventless-in-memory/package.json` extended to also match `*_GWT.res.mjs`.
- [x] Step 5 — `pnpm run build` clean, no warnings/errors. `pnpm test` green at the monorepo level: 176 suites / 1390 tests pass.
- [ ] Step 6 — Show commit message, get approval, commit.
- [ ] Step 7 — User deploys; wipe `PluginAggrEventLog-8e24e73` rows + the stale `Plugin-b3e394e` `Inactive`/`Disconnected` rows for older versions; UI repopulates from heartbeats and from `publishRetireForOlderPluginVersions` for any future deploys.
- [ ] Step 8 — Move plan to `docs/plans/done/` as part of the commit.

## Files (anticipated)

- `reventless/reventless-core/src/admin/PluginSpec.res`
- `reventless/reventless-core/src/admin/PluginBehavior.res`
- `reventless/reventless-core/src/admin/PluginsProjection.res`
- `reventless/reventless-core/src/admin/Platform_EventGraphProjection.res`
- `reventless/reventless-core/src/admin/PluginExtensionPoint_Plugin.res`
- `reventless/reventless-core/src/admin/PluginConnectExtension_Mapping.res`
- `reventless/reventless-aws/src/Platform.res`
- `reventless/reventless-core/src/components/Plugin/Plugin_Builder.res` (if `~version` removal needs a sibling change)
- `reventless/reventless-spec/src/generator/Codegen.res`
- `examples/online-shop-hybrid/*-aws/src/Main.res` (regenerated)
- New: `reventless/reventless-core/tests/admin/PluginBehavior_GWT.res`, `PluginsProjection_GWT.res` (+ fixtures)
