# Plan: Plugin EventCollector runtime rewire (admin → plugin Connect flow)

## Status (2026-05-18)

Steps 1–5 implemented and verified at compile time. Step 6 (live alpha verification) deferred — alpha's existing AdminEventColl HANDLER_CONFIG is still in the old shape, so a `pulumi up` redeploy from the new code is required before the new entry point can parse it; a layer-only patch would crash on cold start at `parseHandlerConfig`. Nothing committed yet.

Build state: `pnpm run build` at repo root — clean across all four ReScript targets, zero warnings.

### Files changed

- [`reventless/reventless-aws/src/adapter/Runtime/AdminEventCollectorEntryPoint.mjs`](../../reventless/reventless-aws/src/adapter/Runtime/AdminEventCollectorEntryPoint.mjs) — full rewrite. Plugin-agnostic, async cold-start cached as a module-level Promise. Drives EP/extension wiring entirely from HANDLER_CONFIG via dynamic imports.
- [`reventless/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res`](../../reventless/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res) — new HANDLER_CONFIG serialiser via `JSON.Encode` (replaces the old string-template path). Reads per-EventCollector context from the new core registry; synthesises an admin context when none registered.
- [`reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res`](../../reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res) — new `eventCollectorContext` type + `eventCollectorContextRef` registry + `registerEventCollectorContext`. `MakeEventCollectorHelper.connect` registers the per-plugin context (including the auto-included Connect entry) before invoking `forPluginEventCollector`.

### Deviations from the original design

1. **`connectExtension` is a top-level singleton field in HANDLER_CONFIG**, not an entry inside `extensions[]` (as originally sketched). The Connect extension is the only thing routed into `incomingConnectExtensionEventHandlers`; promoting it out of `extensions[]` makes the routing semantics explicit and avoids a runtime `isConnect` discriminator. The `extensions[]` array stays as a reserved placeholder for user-declared extensions — entry point warns if non-empty.

2. **moduleUrl propagation: hardcoded framework constants** (the third option offered by Step 4.1). For the current scope (admin Plugin EP + auto-Connect), every moduleUrl is a framework-internal package path — no need for either outputs-field extension (option a) or spec-side `register*` (option b). When user-declared extensions land, the follow-up should extend `Plugin_Helpers.createExtensions` to capture each `Blueprint.moduleUrl` into its returned tuple (mirroring how `ExtensionPoint_Builder` already passes `Spec.moduleUrl`/`Mappings.moduleUrl` to `forCommandTopic`).

3. **Admin context is synthesised inside `forPluginEventCollector`** when the registry has no entry for the EventCollector component name. Means `Platform_Admin.MakeEventCollectorHelper.connect` needs zero changes; the AWS adapter knows it's the AWS adapter and emits admin defaults (fake `pluginDefinition`, `extensionPoints: [Plugin EP]`, `connectExtension: null`). The synthesis uses `ReventlessCore.PluginSpec.name` to key `outgoingExtensionPointEventHandlers["Plugin"]`.

4. **The shared context registry lives in `Plugin_Helpers.res` (core)**, not in `PluginRuntime_Builder.res` (AWS). Lets the AWS adapter consume via `ReventlessCore.Plugin_Helpers.eventCollectorContextRef` without extending the core `PluginRuntime_Builder.T` interface (which would force every adapter — in-memory, micro, single — to implement the registration). In-memory adapters silently ignore the registry.

5. **Cross-plugin subscribe/unsubscribe is deferred at runtime** (matches the plan's Step 5 deferral). The Spec passed to `PluginConnectExtension_Builder.Make` at cold start carries empty `extensionPointsOutputs`/`extensionsOutputs`, so `callHandler`-driven cross-plugin loops iterate empty arrays. Initial Connect populates the Plugin RM; cross-plugin runtime wiring remains a follow-up.

### Checklist roll-up

- [x] Step 1 — HANDLER_CONFIG shape documented in entry-point header (ADR-style block) + `parseHandlerConfig` with field-presence asserts.
- [x] Step 2 — Entry point rewritten against `Plugin_Callback.Make`; epHandlers + connectExtension loops drive the four service-keyed dicts.
- [x] Step 3 — `PluginRuntime_Builder` reads context from `Plugin_Helpers.eventCollectorContextRef`; synthesises admin context when missing; emits new HANDLER_CONFIG via `JSON.Encode`.
- [x] Step 4 — `Plugin_Helpers.connect` registers per-plugin context; moduleUrls hardcoded (rationale in code comment).
- [x] Step 5 — Connect extension auto-included for plugins; admin path leaves `connectExtension: None`.
- [ ] Step 6 — Live alpha verification (deferred). When picked up: `pulumi up` from the new code is the lowest-risk path; manual layer-patch alone won't work because the runtime now rejects the old HANDLER_CONFIG shape.

---

## Problem

After fixing the admin's SNS publish chain (commit `e3418bbf2`), the `CorePluginExtPointEventTopic` SNS topic now successfully delivers `UnknownPluginDetected` events to the per-plugin EventCollector queues (`CatalogPluginEventColl-08a6a08`, `OrderingPluginEventColl-503c1e6`, …). Plugin EventColl Lambdas now fire for the first time. But the `Plugin-b3e394e` RM table stays empty because the plugins never respond with a `ConnectPlugin` command — so the Plugin aggregate never sees a `Connect`, never emits `Connected`, and the `PluginProjection` has nothing to write.

Root cause: every plugin's EventCollector Lambda is wired to `@reventlessdev/reventless-aws/src/adapter/Runtime/AdminEventCollectorEntryPoint.mjs` — hardcoded in [`PluginRuntime_Builder.res:170`](../../reventless/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res#L170) — but that entry point only wires `ExtensionPoint_Operations` for the admin's Plugin EP and publishes outgoing events back to the admin EventTopic. It has no path for plugin-side `Extension_Operations` (where `PluginConnectExtension`'s `mapIncomingEvent` lives), so the entire plugin → admin Connect round-trip is dead.

The deploy-side wiring is shared: both `AdminEventColl-52a6478` (admin) and `CatalogPluginEventColl-689371d` (per-plugin) go through `Plugin_Helpers.MakeEventCollectorHelper.connect` → `PluginRuntimeBuilder.forPluginEventCollector` → the same hardcoded entry-point module. Only the HANDLER_CONFIG content differs (queue URL, etc.).

The runtime abstraction that *does* handle all the cases generically already exists: [`Plugin_Callback.Make`](../../reventless/reventless-core/src/components/Plugin/Plugin_Callback.res#L16) takes a Spec carrying four service-keyed handler dicts (`incomingConnectExtensionEventHandlers`, `outgoingExtensionPointEventHandlers`, `outgoingExtensionEventHandlers`, `incomingExtensionEventHandlers`) and routes incoming events by `meta.service`. The deploy-time `Plugin_Helpers.connect` already builds those dicts and instantiates `Plugin_Callback.Make`. But the bundled Lambda can't reach the deploy-time captured closures, so the entry point currently bypasses `Plugin_Callback` and does its own narrow wiring.

## Fix

Make `AdminEventCollectorEntryPoint.mjs` use `Plugin_Callback.Make` and reconstruct the four handler dicts from HANDLER_CONFIG at cold start — the same dynamic-import pattern `ReadModelEntryPoint.mjs` already uses for ReadModel spec/mappings modules. The entry point becomes plugin-agnostic; admin and every plugin Lambda just differ by HANDLER_CONFIG content.

The plan breaks into the runtime side (new HANDLER_CONFIG shape + entry-point rewrite) and the deploy side (build that HANDLER_CONFIG from outputs already available inside `Plugin_Helpers.connect`), plus a manual verification loop against the alpha stack.

---

## Step 1 — Define the new HANDLER_CONFIG shape

Document the contract before either side changes. Target shape (JSON, base64-or-string serialised into an env var as today):

```json
{
  "queueUrl": "https://sqs.../<EventColl>-<hash>",
  "pluginExtensionPointCmdTopicUrl": "https://sqs.../CorePluginExtPointCmdTopic-<hash>",
  "eventTopicArn": "arn:aws:sns:eu-west-1:000000000000:CorePluginExtPointEventTopic-<hash>",
  "pluginReadModelTableName": "Plugin-<hash>",
  "appSyncApiId": "wbbmwqjun…",
  "clonerEnabled": false,
  "schedulerRoleArn": "arn:aws:iam::…:role/CloudWatchEventsRole-<hash>",
  "schedulerQueueArn": "arn:aws:sqs:…:CorePluginExtPointCmdTopic-<hash>",
  "schedulerQueueName": "CorePluginExtPointCmdTopic-<hash>",

  "pluginDefinition": {
    "id": "Catalog@1.0.0-alpha.44",
    "name": "Catalog",
    "version": "1.0.0-alpha.44",
    "eventCollector": "arn:aws:sqs:…:CatalogPluginEventColl-<hash>",
    "extensionPoints": [
      { "name": "Catalog.Products", "eventTopic": "arn:aws:sns:…" }
    ],
    "extensions": [
      { "name": "<n>", "extensionPointName": "Core.Plugin" }
    ],
    "extensionProtocols": [],
    "apiSchemaFragment": null
  },

  "extensionPoints": [
    {
      "specModule": "@reventlessdev/reventless-core/src/admin/PluginExtensionPointSpec.res.mjs",
      "mappingsModule": "@reventlessdev/reventless-core/src/admin/PluginExtensionPoint_Plugin.res.mjs",
      "eventTopicArn": "arn:aws:sns:…:CorePluginExtPointEventTopic-<hash>"
    }
  ],

  "extensions": [
    {
      "specModule": "@reventlessdev/reventless-infra/src/types/PluginExtensionPointSpec.res.mjs",
      "mappingsModule": "@reventlessdev/reventless-core/src/admin/PluginConnectExtension_Builder.res.mjs",
      "extensionPointName": "Core.Plugin"
    }
  ],

  "publishToAggregates": {
    "Plugin": "PTA_Plugin_QUEUE_URL"
  },
  "readModelTables": {
    "Plugin": "Plugin-<hash>"
  }
}
```

Per-context content:

| Lambda | extensionPoints | extensions | Notes |
|---|---|---|---|
| `AdminEventColl-*` | `[{Plugin EP}]` | `[]` | Admin processes outgoing events of its own Plugin EP. `pluginDefinition` carries fake admin id (existing fakePluginDefinition pattern). |
| `<Plugin>PluginEventColl-*` | `[]` | `[{Connect}]` (auto-included) plus any user-declared extensions | Plugin EventColls process incoming events from other plugins' EventTopics and route Connect commands back. |

`pluginExtensionPointCmdTopicUrl` is required for both — for the admin it's its own EP queue (for reflexive PublishExtensionPointCommand directives, currently unused but harmless to include); for plugins it's where `ConnectPlugin` commands go.

### Checklist

```
Step 1
  [ ] 1.1  Add ADR-style block at the top of AdminEventCollectorEntryPoint.mjs documenting the HANDLER_CONFIG schema (above)
  [ ] 1.2  Write a `parseHandlerConfig(rawJson) → typed config` JS helper inside the entry point with field-presence asserts that fail loudly at cold start
  [ ]      Verify: cold start with a known-bad config (missing pluginDefinition) crashes with a clear error, not a silent undefined deref
```

---

## Step 2 — Rewrite `AdminEventCollectorEntryPoint.mjs` against `Plugin_Callback.Make`

File: `reventless/reventless-aws/src/adapter/Runtime/AdminEventCollectorEntryPoint.mjs`

Replace the hardcoded `extensionPointOperationsMake(patchedSpec)(mappingsModule)(...)` block with a generic builder driven by HANDLER_CONFIG. Pseudocode:

```js
async function buildHandler() {
  const config = parseHandlerConfig(process.env["HANDLER_CONFIG"]);

  // Reconstruct runtimeOps + queryEngine + scheduler — already done today, no change.
  const runtimeOps = {…};
  const queryEngine = {…};
  const scheduler = {createSchedule: cwCreateSchedule(config.schedulerRoleArn), deleteSchedule: cwDeleteSchedule};
  const commandTopicResources = config.schedulerQueueArn !== ""
    ? [{name: config.schedulerQueueName, id: …, urn: config.schedulerQueueArn, …}]
    : [];
  const resourceNaming = {validateName: …, urnName: …};

  // EP operations — one per declared extensionPoint (admin: 1; plugins: 0)
  const epHandlers = await Promise.all(config.extensionPoints.map(async (ep) => {
    const specMod = patchSpecId(await dynamicImport(ep.specModule));
    const mappingsMod = await dynamicImport(ep.mappingsModule);
    // mappingsMod exposes `.Make` (e.g. pluginEPPluginMake) — call with runtimeOps, environment, updateApiSchema
    const epModule = mappingsMod.Make({ runtimeOps, environment, updateApiSchema });
    const mappingsModule = { mappings: [epModule.Mapping] };
    const resolvedTopic = {name: ep.eventTopicArn, id: ep.eventTopicArn, arn: ep.eventTopicArn};
    const ops = extensionPointOperationsMake(specMod)(mappingsModule)({
      publishToEventTopic: (id, meta, json) => snsPublish(resolvedTopic, id, meta, json),
      commandTopicResources, scheduler, queryEngine, resourceNaming,
    });
    return { spec: specMod, ops };  // .ops.outgoingJsonEventsHandler is what Plugin_Callback needs
  }));

  // Extension operations — one per declared extension (admin: 0; plugins: 1+)
  const extHandlers = await Promise.all(config.extensions.map(async (ext) => {
    const specMod = patchSpecId(await dynamicImport(ext.specModule));   // extension point spec
    const mappingsMod = await dynamicImport(ext.mappingsModule);         // extension's Make
    // For PluginConnectExtension_Builder.Make, the Spec needs pluginDefinition + (empty) outputs + runtimeOps + resourceNaming
    const extModule = mappingsMod.Make({
      pluginDefinition: config.pluginDefinition,
      extensionPointsOutputs: [],   // see Step 5 — empty defers cross-plugin subscribe/unsubscribe
      extensionsOutputs: [],
      runtimeOps,
      resourceNaming,
    });
    const mappingsModule = { Spec: specMod, name: extModule.name, mappings: [extModule.ConnectPluginMapping] };
    const ops = extensionOperationsMake(specMod)(mappingsModule)({
      publishToAggregates: buildPublishToAggregates(config.publishToAggregates),
      publishToPluginExtensionPoint: sqsPublishJsons(makeQueueRef(config.pluginExtensionPointCmdTopicUrl), "SQS_FIFO"),
      readModelNamesForSourceName: {}, // empty for connect-only; populate when user RMs are added
      publishToReadModels: {},
      queryEngine,
    });
    return { spec: specMod, extensionPointName: ext.extensionPointName, ops };
  }));

  // Build the four service-keyed dicts that Plugin_Callback.Make expects.
  const dictByService = (entries) => entries.reduce((acc, [svc, handler]) => {
    (acc[svc] ??= []).push(handler);
    return acc;
  }, {});

  const outgoingExtensionPointEventHandlers = dictByService(epHandlers.flatMap(({spec, ops}) =>
    // Outgoing handler keyed by aggregateNames (deploy uses outputs.aggregateNames; runtime fallback: spec.name)
    [[spec.name, ops.outgoingJsonEventsHandler]]
  ));
  const incomingConnectExtensionEventHandlers = dictByService(extHandlers.flatMap(({extensionPointName, ops}) =>
    [[extensionPointName, ops.incomingJsonEventsHandler]]
  ));
  const outgoingExtensionEventHandlers = {};       // user-extensions outgoing — defer
  const incomingExtensionEventHandlers = {};       // user-extensions incoming — defer

  const callback = pluginCallbackMake({
    pluginDefinition: config.pluginDefinition,
    incomingConnectExtensionEventHandlers,
    outgoingExtensionPointEventHandlers,
    outgoingExtensionEventHandlers,
    incomingExtensionEventHandlers,
  });

  return handleDynamoDbOrSqsEvent(makeQueueRef(config.queueUrl), callback.handleJsonEvents);
}
```

Things to keep from today's implementation:
- `mkUpdateApiSchema` (the AppSync schema stitcher) becomes part of the `epHandlers` setup — passed to `pluginEPPluginMake` as `updateApiSchema`. Only set when `config.appSyncApiId !== "NOT_AVAILABLE"`.
- `requestContextTag` provideService wrapper around `runEffect`.
- `extractCorrelationId` for log correlation.

### Checklist

```
Step 2
  [ ] 2.1  Move existing admin-specific instantiation into the `epHandlers.map` loop driven by `config.extensionPoints`
  [ ] 2.2  Add `extHandlers.map` loop driven by `config.extensions`; instantiate Extension_Operations.Make per entry
  [ ] 2.3  Build the four service-keyed dicts and wire `Plugin_Callback.Make`
  [ ] 2.4  Replace ad-hoc handleJsonEvents stream with the callback.handleJsonEvents output
  [ ] 2.5  Preserve mkUpdateApiSchema behaviour (admin only — appSyncApiId conditional)
  [ ]      Verify: admin lambda cold-starts cleanly with the admin HANDLER_CONFIG, processes a heartbeat-driven UnknownPluginDetected, logs "applying event" (parity with today's behaviour)
```

---

## Step 3 — `PluginRuntime_Builder.forPluginEventCollector` HANDLER_CONFIG build-up

File: `reventless/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res`

Today's `forPluginEventCollector` writes a flat HANDLER_CONFIG from `configRef.contents` + `extras`. It needs:
1. To accept (or read from a ref) `pluginDefinition`, `extensionPoints` list, `extensions` list, `pluginExtensionPointCmdTopicUrl`, `publishToAggregates` map.
2. To serialise them into the new HANDLER_CONFIG JSON shape from Step 1.

The simplest signature-compatible path: add a second register function, e.g.:

```rescript
type eventCollectorContext = {
  pluginDefinition: Pulumi.Output.t<Reventless.Plugin.pluginDefinition>,
  extensionPoints: array<{specModule: string, mappingsModule: string, eventTopicArn: Pulumi.Output.t<string>}>,
  extensions: array<{specModule: string, mappingsModule: string, extensionPointName: string}>,
  pluginExtensionPointCmdTopicUrl: Pulumi.Output.t<string>,
  publishToAggregates: dict<Pulumi.Output.t<string>>,
}

let eventCollectorContextRef: ref<dict<eventCollectorContext>> = ref(Dict.make())
let registerEventCollectorContext = (~componentName: string, ~ctx: eventCollectorContext) =>
  eventCollectorContextRef.contents->Dict.set(componentName, ctx)
```

`forPluginEventCollector` looks up the context by EventCollector component name and serialises into HANDLER_CONFIG via `Pulumi.Output.apply` chains (the existing pattern for queueUrl etc.).

### Checklist

```
Step 3
  [ ] 3.1  Add `eventCollectorContext` type and `registerEventCollectorContext` to PluginRuntime_Builder
  [ ] 3.2  Update `forPluginEventCollector` to read the context, fall back to admin-only behaviour if absent (parity)
  [ ] 3.3  Serialise the new fields into HANDLER_CONFIG via Pulumi.Output.all-then-apply (mirror existing JSON-template pattern)
  [ ]      Verify: building one plugin produces a HANDLER_CONFIG with the expected pluginDefinition + extensions list visible via `pulumi preview`
```

---

## Step 4 — `Plugin_Helpers.MakeEventCollectorHelper.connect` populates the context

File: `reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res`

Inside the inner `Pulumi.Output.apply` (around line 377) that already has `pluginDefinition`, `extensionPointsOutputs`, `extensionsOutputs` resolved, call the new register before `eventCollector->PluginRuntimeBuilder.forPluginEventCollector(...)`.

Required derivations:
- `pluginDefinition` — already in scope as a Pulumi.Output (resolved inside the apply).
- `extensionPoints[].specModule` / `mappingsModule` — derived from each EP's blueprint moduleUrl. The Blueprint module type carries `moduleUrl`, but the deploy-time outputs don't (see "Honest concern #1"). Need to either:
  - (a) extend `ExtensionPoint.outputs` and `Extension.outputs` with `moduleUrl: string` (Pulumi.Output<string>), populated by each component's `make`, OR
  - (b) use a `register*` pattern on the spec side (each Spec/Blueprint registers its moduleUrl in a ref keyed by name; `connect` looks them up).
- `publishToAggregates` — already wired via `PluginRuntime_Builder.configRef`-like infra; reuse.

### Checklist

```
Step 4
  [ ] 4.1  Pick (a) or (b) for moduleUrl propagation; document rationale in code comment
  [ ] 4.2  Wire each Extension/EP's moduleUrl into the chosen channel
  [ ] 4.3  Build the eventCollectorContext inside Plugin_Helpers.connect, call registerEventCollectorContext before forPluginEventCollector
  [ ]      Verify: rerun `pulumi preview` — the HANDLER_CONFIG for CatalogPluginEventColl now contains the Connect extension entry with the correct module specifiers
```

---

## Step 5 — Auto-include `PluginConnectExtension` for every plugin

For plugins that haven't explicitly declared extensions, the Connect flow still has to work. The cleanest path: have `Plugin_Helpers.connect` (or a sibling helper) always append the `PluginConnectExtension` entry to the `extensions` list passed into the context — even when the user-supplied list is empty.

Defer the cross-plugin subscribe/unsubscribe path (the `callHandler`-based `DoConnectPlugin`/`DoDisconnectPlugin` directives). The Spec passed to `PluginConnectExtension_Builder.Make` at runtime carries empty `extensionPointsOutputs`/`extensionsOutputs` arrays, so those directives silently no-op. Connect itself works because it only depends on `Spec.pluginDefinition`.

### Checklist

```
Step 5
  [ ] 5.1  Auto-prepend the PluginConnectExtension entry to `extensions` in the registered context
  [ ] 5.2  Document the empty-outputs deferral in a code comment so future readers know the cross-plugin path is dormant
  [ ]      Verify: a plugin with zero user-declared extensions still gets a Connect entry visible in HANDLER_CONFIG
```

---

## Step 6 — Live verification on the alpha stack

Manual loop (each cycle ~3 min):

1. Build reventless-core + reventless-aws (`pnpm run build`).
2. Copy the 4 changed `.res.mjs` files into the staged layer (`/tmp/layer-patch/layer-new/nodejs/node_modules/...`).
3. `zip -qr layer<N>-patched.zip .` from inside the staged layer dir.
4. `aws lambda publish-layer-version --layer-name reventless-aws-alpha --zip-file fileb:///tmp/layer<N>-patched.zip --compatible-runtimes nodejs20.x nodejs22.x`.
5. Update HANDLER_CONFIG via `aws lambda update-function-configuration --environment file://…` for `AdminEventColl-52a6478`, `CatalogPluginEventColl-689371d`, `OrderingPluginEventColl-0805c61`. Repoint to the new layer ARN.
6. `aws lambda invoke --function-name CatalogPluginHeartbeat-eabe0ac --payload '{}' /tmp/out.txt`.
7. Tail logs in parallel: `AdminEventColl`, `CatalogPluginEventColl`, `AllAggregates-712c9fb`.
8. Scan `Plugin-b3e394e` table — expect a `Connected` row for the heartbeat plugin within one tick.

### Checklist

```
Step 6
  [ ] 6.1  Admin cold-start logs "applying event: UnknownPluginDetected" (parity with today)
  [ ] 6.2  Plugin EventColl logs "incoming event: UnknownPluginDetected" then "EP→Plugin: ConnectPlugin"
  [ ] 6.3  AllAggregates-712c9fb logs "produced 1 event(s): [Connected(<plugin-id>)]" then "append: id=<plugin-id>"
  [ ] 6.4  AllReadModels-4d12ee0 logs "handling event ... actions:[Set(...)]"
  [ ] 6.5  `aws dynamodb scan --table-name Plugin-b3e394e` shows a row for Catalog@<version>
  [ ]      Verify: end-to-end Connect round-trip is functional on alpha
```

---

## Honest concerns / unresolved

1. **`pluginDefinition` shape contains nested Pulumi Outputs** (`extensionPoints[].eventTopic`, `eventCollector` URN). Serialising to JSON requires unwrapping `Output<Output<…>>` — non-trivial. Pattern to mirror: the way `extensionPointsOutputs` is currently flattened in `Plugin_Helpers.connect` via `Pulumi.Output.all`.

2. **Cross-plugin subscribe/unsubscribe is deferred.** With `extensionPointsOutputs: []` passed to the Connect extension at runtime, the `DoConnectPlugin` path's subscribe loop iterates over an empty array — silently does nothing. This is OK for the initial Connect (Plugin RM populates), but means plugins won't dynamically wire themselves to *other* plugins' EPs at runtime. A follow-up plan should address this: probably propagate the relevant peer-plugin EP info through HANDLER_CONFIG too, or have the admin handle all subscription management.

3. **Functor application from .mjs is fragile.** `PluginConnectExtension_Builder.Make(Spec)` and friends compile to JS factory calls — getting the Spec object shape right requires care (we hit this exact class of bug with `Util_PulumiShim`/`patchSpecId` earlier this session). Recommendation: write a tiny smoke test (Node script) that constructs the same Spec shape and calls `Make` locally, verifies the returned object has the expected `.ConnectPluginMapping` etc. — cheaper than the manual layer-patch loop.

4. **Admin lambda must not regress.** The admin currently works (modulo Plugin RM population). The new entry point needs to handle admin's `extensionPoints: [{Plugin EP}], extensions: []` configuration as a strict superset of today's behaviour. Step 2.5's verification gate is load-bearing.

## Out of scope

- User-declared plugin extensions beyond `PluginConnectExtension` (their `incoming`/`outgoing` handlers, RM enqueues). Once Step 5 lands, the entry-point structure already supports them; the Plugin_Helpers wiring would just need to forward user extensions into the same `extensions[]` array.
- Plugin-side ReadModel projections triggered from incoming events (`publishToReadModels` / `readModelNamesForSourceName`). Same as above — structure is ready, wiring is a follow-up.
- DCB EventLog → Plugin EventCollector routing (currently a separate path; out of this plan).

## References

- [Plugin_Callback.Make](../../reventless/reventless-core/src/components/Plugin/Plugin_Callback.res#L16) — the generic routing primitive
- [Extension_Operations.Make](../../reventless/reventless-core/src/components/Extension/Extension_Operations.res#L24) — per-extension Ops constructor
- [PluginConnectExtension_Builder.Make](../../reventless/reventless-core/src/admin/PluginConnectExtension_Builder.res#L12) — the built-in Connect extension
- [Plugin_Helpers.MakeEventCollectorHelper.connect](../../reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res#L304) — current deploy-time wiring (works today, but bypassed at runtime)
- Commit `e3418bbf2` — the upstream admin SNS publish fix (unblocked plugin EventColl invocation)
