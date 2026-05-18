# Plan: Plugin EventCollector runtime rewire — generic (user extensions + plugin RMs)

## Status (2026-05-18) — partial; Steps 1–3b landed, Step 4 broken out into 4a–4e

What landed on branch `plugin-ec-rewire-generic`:

- [x] **Step 1** — HANDLER_CONFIG schema extended (per-extension `aggregateNames` / `readModelNames`, top-level `readModelQueueUrls`, top-level `readModelNamesForSourceName`). Parser defaults all new fields to empty so the admin Lambda's existing HANDLER_CONFIG stays valid.
- [x] **Step 2** — PPX `@@reventless.extension` already injects `moduleUrl`; verified `examples/online-shop-hybrid/catalog/src/Extension/Orders_Extension.res.mjs` exports the right specifier. No PPX rebuild needed.
- [x] **Step 3** — `Plugin_Helpers.eventCollectorContext` extended with `extensions: array<extensionEntry>`, `readModelQueueUrls`, `readModelNamesForSourceName`. `createExtensions` returns a third element (`extensionRegistryInfos`) carrying per-merged-group `specModule` + `mappingsModule` derived from `Spec.moduleUrl` / `First.moduleUrl`. `Plugin_Builder` computes `aggregateQueueUrls` from `aggregateResources` + `dcbResult.dcbCommandTopicQueueUrl` (newly exposed) and `readModelQueueUrls` from `readModelsOutputs[*].eventCollector.resources[0].id`. Both call sites of `MakeEventCollectorHelper.connect` pass the new args. Dcb_Builder surfaces `dcbCommandTopicQueueUrl: option<Pulumi.Output.t<string>>` from the new dcbResult field.
- [x] **Step 3b** — `PluginRuntime_Builder.forPluginEventCollector` serialises the new fields into HANDLER_CONFIG, emits `PTA_<agg>_QUEUE_URL` for every aggregate/slice queue and `PRM_<rm>_QUEUE_URL` for every RM queue. Admin-context synthesis defaults the new fields to empty so admin Lambda config keeps the same shape.
- [x] **Step 4** — Entry-point user-extension dispatch — **4a–4d landed; 4e in-memory already wired previously, AWS deferred to cross-plugin plan.** Background: see [Step 4 — gap analysis](#step-4--gap-analysis). Sub-step status:
  - [x] **4a** — PPX injects `let delegateModuleUrl = Delegate.moduleUrl` inside `module Mapping`; both ppx binaries rebuilt (commit `01530ab11`).
  - [x] **4b** — `Plugin_Helpers.extensionRegistryInfo` + `extensionEntry` carry `delegateModule: string`; also fixed pre-existing `Blueprint.moduleUrl = Mapping.Delegate.moduleUrl` bug — `Blueprint.moduleUrl` now points at the user extension file (commit `9832aa1f4`).
  - [x] **4c** — `PluginRuntime_Builder.forPluginEventCollector` bundles all three user packages into the Lambda asset and serialises `delegateModule` into HANDLER_CONFIG (commit `08098b1f5`).
  - [x] **4d** — `AdminEventCollectorEntryPoint.mjs` placeholder replaced with three-import reconstruction → `extensionMappingMake` → per-extension `Extension_Operations.Make` → handlers registered in `incomingExtensionEventHandlers` / `outgoingExtensionEventHandlers` (commit `bbb877aca`).
  - [x] **4e (in-memory)** — Already wired via `Bus.subscribeEventCollectorToTopic` in the in-memory `makePlatform` (Platform.res:1281-1297). Combined with 4a–4d, in-memory cross-plugin extensions are end-to-end functional. AWS split-stack deferred to the cross-plugin rewire plan.
- [ ] **Step 5** — Alpha verification — **blocked on cross-plugin rewire plan** (AWS deployPlugin needs arbitrary peer-plugin StackReferences before catalog can subscribe to ordering's EP EventTopic). Local in-memory E2E verification of the full chain is unblocked.

Build state: `pnpm run build` at repo root compiles all 907 framework modules clean (the examples in-memory build failure is a pre-existing pnpm workspace name-resolution issue, unrelated to these changes).

## Step 4 — gap analysis

The plan's original Step 4 sketch (`extensionOperationsMake(specMod)(mappingsModule)({...})`) hand-waves over the runtime mapping reconstruction. Concretely:

1. **Delegate moduleUrl is not surfaced by today's Blueprint.** Each user `*_Extension.res` declares `module Delegate = <SliceOrAggregate>` inside its `Mapping` module. `Platform.Extension.Make(Orders_Extension.Mapping)` consumes that Delegate during functor application — `Delegate.moduleUrl` / `Delegate.commandSchema` etc. are baked into the compiled `Plugin.res.mjs` but no longer accessible via `ReventlessInfra.Extension.Blueprint`. The `extensionRegistryInfo` returned by Step 3's `createExtensions` therefore only carries the EP spec + user-mapping module URLs, not the Delegate's URL.

2. **The Plugin EventCollector Lambda asset has no user code today.** `PluginRuntime_Builder.forPluginEventCollector` calls `Util_Bundle.buildCodeArchive(..., ~packageDirs=Dict.make())` — only the framework entry point ships; the plugin's package (e.g. `@reventlessdev/online-shop-hybrid-catalog`) and the EP-spec package (e.g. `@reventlessdev/online-shop-hybrid-ordering-spec`) are absent. A dynamic-import of the user's `Orders_Extension.res.mjs` at cold start would fail with `ERR_MODULE_NOT_FOUND`. The fix mirrors the per-EP / per-aggregate builders (`EventCollectorRuntime_Builder_PerEventCollector.res:79–84`, `AggregateRuntime_Builder_Micro.res:193–196`): extract package names from each extension's module specifiers and feed them into `packageDirs`.

3. **The compiled user mapping has the wrong shape for `Extension_Operations.Make`.** `Orders_Extension.res.mjs` exports `Mapping = {ExtensionPoint: undefined, Delegate: undefined, mapIncomingEvent, mapOutgoingEvent}` — ReScript erases unused module references in the JS layer, so the user mapping alone can't satisfy `ExtensionMapping.Mapping`. The runtime needs three dynamic-imports (EP spec, Delegate spec, user mapping) and an explicit reconstruction:

   ```js
   const userMapping = (await import(ext.mappingsModule)).Mapping;
   const epSpec = patchSpecId(await import(ext.specModule));
   const delegateSpec = await import(ext.delegateModule);  // ← new HANDLER_CONFIG field
   const fullMapping = {
     ExtensionPoint: epSpec,
     Delegate: delegateSpec,
     mapIncomingEvent: userMapping.mapIncomingEvent,
     mapOutgoingEvent: userMapping.mapOutgoingEvent,
   };
   const transformedMapping = extensionMappingMake(fullMapping);
   const mappingsModule = { Spec: epSpec, name: ext.name, mappings: [transformedMapping] };
   const ops = extensionOperationsMake(epSpec)(mappingsModule)({...});
   ```

   `extensionMappingMake` lives at `@reventlessdev/reventless-infra/src/types/ExtensionMapping.res.mjs` (runtime-safe — only depends on sury + reventless-spec).

### Resolution

These three issues are now addressed as sub-steps in the expanded Step 4 below: **4a** (PPX surfaces `Delegate.moduleUrl`), **4b** (`Plugin_Helpers` threads it through), **4c** (`PluginRuntime_Builder` bundles user packages and serialises the new field), **4d** (entry point does the three-import reconstruction). **4e** covers the subscription bootstrap soft-prereq.

Everything in `Plugin_Helpers` / `PluginRuntime_Builder` from Steps 1–3b is structured so this expansion adds a single new field per entry plus the entry-point reconstruction. No further changes to the per-Lambda HANDLER_CONFIG schema are expected.

---

## Original problem statement

Follow-up to [plugin-eventcollector-runtime-rewire.md](./plugin-eventcollector-runtime-rewire.md) (the "minimal" plan). That plan wires the built-in `PluginConnectExtension` only, so admin-issued `UnknownPluginDetected` events round-trip into `Connect` and the Plugin RM populates. This plan extends the same entry-point and HANDLER_CONFIG mechanics to:

- **User-declared extensions** (`@@reventless.extension`-annotated `*_Extension.res` files — already used in `examples/online-shop-*/`).
- **Plugin-local read models** that those extensions feed into (`publishToReadModels` + `readModelNamesForSourceName`).
- **Multiple aggregates per plugin** publishing commands from extension handlers (`publishToAggregates` populated with real queue URLs, not just the admin's Plugin aggregate).

Prerequisite: the minimal plan must be complete and verified. The HANDLER_CONFIG schema, register pattern, and entry-point structure introduced there form the foundation here. This plan only adds fields and code paths; no breaking changes.

Explicitly **out of scope** (deferred to a third plan): the cross-plugin runtime subscribe/unsubscribe path (`DoConnectPlugin`/`DoDisconnectPlugin` → `Spec.runtimeOps.topicSubscription.subscribeChannelToTopic`). That's a separate, larger change requiring peer-plugin EP outputs to be serialised through HANDLER_CONFIG.

## Problem

Even after the minimal plan lands:

1. `examples/online-shop-hybrid/catalog/src/Extension/Orders_Extension.res` declares an extension that subscribes to Ordering's `Orders_ExtensionPoint` and emits `RecordProductDemand` state-change-slice commands. With the minimal plan's HANDLER_CONFIG, this extension never reaches the catalog plugin's bundled Lambda — the runtime only knows about `PluginConnectExtension`. Catalog's `CatalogPluginEventColl-689371d` would receive `ItemOrdered` events (once cross-plugin subscriptions exist) but have no handler.
2. Plugin-local read models that user extensions feed into (e.g. `ProductDemands` populated from `RecordProductDemand` slice events) need `readModelNamesForSourceName` + `publishToReadModels` populated in the Extension_Operations Ops. The minimal plan stubs both as `{}` — fine for ConnectPlugin, broken for any user extension that writes to a plugin RM.
3. User extensions whose `mapIncomingEvent` returns `PublishAggregateCommand(<aggName>, <cmd>)` need `publishToAggregates` keyed by the plugin's *own* aggregates, not just the admin's Plugin aggregate. The minimal plan only ever puts `Plugin` in that map.

## Fix

Extend the HANDLER_CONFIG shape and the register/serialise pipeline to carry user-extension and plugin-local-RM metadata. Reuse the entry-point's existing `config.extensions.map(…)` and Extension_Operations.Make instantiation loop — just feed it richer config.

The plan splits into:
- **Step 1** — HANDLER_CONFIG schema extension (what to add, who needs each field)
- **Step 2** — PPX / blueprint-side propagation (each `@@reventless.extension` file's moduleUrl flows to the runtime)
- **Step 3** — Deploy-side wiring (`Plugin_Helpers` populates the richer context)
- **Step 4** — Entry-point user-extension dispatch, broken into:
  - **4a** — PPX exposes `Delegate.moduleUrl` on the extension's `Mapping` module
  - **4b** — `Plugin_Helpers` threads `delegateModule` through `extensionRegistryInfo`
  - **4c** — `PluginRuntime_Builder` bundles user packages and serialises `delegateModule`
  - **4d** — Entry-point three-import reconstruction + real Ops wiring
  - **4e** — Subscription bootstrap (deploy-time pre-subscription, soft prereq for Step 5)
- **Step 5** — Live verification on alpha with the existing online-shop-hybrid example

---

## Step 1 — HANDLER_CONFIG schema extension

The minimal plan's HANDLER_CONFIG already has an `extensions: [{specModule, mappingsModule, extensionPointName}]` array. Extend each entry:

```json
"extensions": [
  {
    "name": "Orders_Extension",
    "specModule": "@reventlessdev/online-shop-hybrid-catalog/src/Extension/Orders_Extension.res.mjs",
    "mappingsModule": "@reventlessdev/online-shop-hybrid-catalog/src/Extension/Orders_Extension.res.mjs",
    "extensionPointName": "Ordering.Orders",
    "aggregateNames": ["RecordProductDemand"],
    "readModelNames": ["ProductDemands"]
  },
  {
    "name": "Connect",
    "specModule": "@reventlessdev/reventless-infra/src/types/PluginExtensionPointSpec.res.mjs",
    "mappingsModule": "@reventlessdev/reventless-core/src/admin/PluginConnectExtension_Builder.res.mjs",
    "extensionPointName": "Core.Plugin",
    "aggregateNames": [],
    "readModelNames": []
  }
]
```

Top-level additions:

```json
"publishToAggregates": {
  "Plugin": "PTA_Plugin_QUEUE_URL",
  "RecordProductDemand": "PTA_RecordProductDemand_QUEUE_URL"
},
"readModelTables": {
  "ProductDemands": "ProductDemands-<hash>"
}
```

The `aggregateNames` / `readModelNames` per extension are derived from each Extension's `outputs.aggregateNames` and from `readModelNamesForSourceName` (which is currently built deploy-side by inverting the readmodel ↔ source-name index). Carrying them per-extension lets the entry-point construct each Extension_Operations.Ops with the *subset* the extension actually touches — keeps the bundled handler from holding refs to unrelated infra.

Top-level `publishToAggregates` carries the union; per-extension `aggregateNames` is a filter into it.

### Checklist

```
Step 1
  [ ] 1.1  Update the HANDLER_CONFIG schema doc block in AdminEventCollectorEntryPoint.mjs
  [ ] 1.2  Update parseHandlerConfig asserts (Step 1 of the minimal plan) to recognise the new fields with sensible defaults (empty arrays for legacy admin config)
  [ ]      Verify: admin lambda still cold-starts with its admin-only HANDLER_CONFIG (no extensions, no plugin aggregates)
```

---

## Step 2 — Propagate Extension moduleUrls from blueprints to the deploy-side context

The minimal plan defers this decision to "Step 4.1 (a) or (b)". Pick option (b) — **register pattern via the existing PPX**. Rationale:

- `@@reventless.extension` already injects boilerplate; adding a `let moduleUrl: string = %raw('import.meta.url')` injection is one line in the PPX (matches `@@reventless.spec` and friends).
- Every Extension blueprint module already conforms to `ReventlessInfra.Extension.Blueprint` which has `let moduleUrl: string` in its module type (line 54 of `Extension.res`). The user-facing files don't define one today — they rely on the PPX.
- The Plugin generator (`generate-plugin`) walks each plugin's `src/Extension/` and emits the wiring; that wiring already references each blueprint by module path — easy place to grab the path string.

The deploy-side context's `extensions[]` then carries `{specModule, mappingsModule, extensionPointName, aggregateNames, readModelNames}` populated from each blueprint module's exports plus deploy-time outputs (`aggregateNames` lives on `Extension.outputs`).

The merged-per-EP case (multiple `_Extension.res` files for one EP get combined in `Plugin_Helpers.connect` around line 158-174) needs special handling: the runtime needs to be able to call ONE `Extension_Operations.Make` per merged group, not per blueprint. Either:
- (i) Pass merged groups in HANDLER_CONFIG with `mappingsModule[]` arrays, or
- (ii) Have the entry point do the merge itself by grouping `extensions[]` by `extensionPointName` and concatenating mappings arrays after dynamic import.

Option (ii) is simpler — the entry point already has every loaded mappings module in hand by the time it instantiates Ops, so grouping is a one-liner.

### Checklist

```
Step 2
  [ ] 2.1  Update reventless-ppx @@reventless.extension transformer to auto-inject moduleUrl if absent (mirrors @@reventless.spec)
  [ ] 2.2  Rebuild ppx-macos + ppx-linux binaries (Docker for Linux per MEMORY.md feedback_ppx_linux_rebuild)
  [ ] 2.3  Confirm existing user-facing extension files compile cleanly with the new injection (no double moduleUrl)
  [ ]      Verify: any *_Extension.res.mjs file exports a non-empty moduleUrl string at runtime
```

---

## Step 3 — Deploy-side wiring populates the richer context

File: `reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res` (around the existing `mergeExtensionsByExtensionPointName` block at line 145-194).

Inside the `Pulumi.Output.apply` that resolves `extensionsOutputs`, walk each blueprint and emit one entry per Extension component (post-merge). For each:

```rescript
{
  name: extensionOutputs.name,
  specModule: First.Spec.moduleUrl->Util_Bundle.getModuleSpecifier,  // ExtensionPoint spec
  mappingsModule: First.moduleUrl->Util_Bundle.getModuleSpecifier,   // The merged blueprint's URL (use first member's)
  extensionPointName: First.Spec.name,
  aggregateNames: extensionOutputs.aggregateNames,
  readModelNames: deriveReadModelNamesForExtension(extensionOutputs, readModelNamesForSourceName),
}
```

For top-level `publishToAggregates`:
- The admin's `Plugin` aggregate is already covered today (queue URL flows through the `PTA_Plugin_QUEUE_URL` env var pattern set up for `CorePluginExtPointCmdTopic`).
- For plugin-local aggregates (`RecordProductDemand`, etc.), reuse the same env-var-name convention. The plugin's `allCommandTopics` (already in scope in `Plugin_Builder`) gives the mapping; thread it into `forPluginEventCollector` via the new register call from the minimal plan's Step 3.

For top-level `readModelTables`: similar — the plugin's own RMs are in scope in `Plugin_Builder`. Pass the `name → table-name` dict via the register call.

### Checklist

```
Step 3
  [ ] 3.1  Extend `eventCollectorContext` (from minimal plan Step 3) with the new fields
  [ ] 3.2  Update `Plugin_Helpers.MakeEventCollectorHelper.connect` to populate them from `extensionsOutputs`, `allCommandTopics`, plugin-local RM outputs
  [ ] 3.3  Extend the HANDLER_CONFIG JSON template in `forPluginEventCollector` to serialise the new fields
  [ ]      Verify: `pulumi preview` shows a CatalogPluginEventColl HANDLER_CONFIG carrying Orders_Extension with the right extensionPointName + aggregateNames
```

---

## Step 4 — Entry-point user-extension dispatch (expanded)

Steps 1–3b leave one cold-start gap: the Plugin EventCollector Lambda's `extHandlers.map(...)` loop falls through to `console.warn("user extensions in HANDLER_CONFIG are not yet wired …")` for everything except `PluginConnectExtension`. The [gap analysis](#step-4--gap-analysis) above identified three concrete causes:

1. `Delegate.moduleUrl` isn't on the Blueprint.
2. The Lambda asset doesn't include the user's package or the EP-spec package.
3. The compiled user mapping (`Orders_Extension.res.mjs`) only carries `mapIncomingEvent` / `mapOutgoingEvent` — `ExtensionPoint` and `Delegate` are erased.

Sub-steps 4a–4d close all three; 4e covers the subscription soft-prereq.

### Findings (2026-05-18) — pre-implementation verification

Code references confirmed before starting 4a:

| Concern | Location | Current state |
|---|---|---|
| PPX extension dispatch | [`ReventlessPpx.ml:572-605`](../../packages/reventless-ppx/src/ppx/ReventlessPpx.ml#L572-L605) | Walks `module Mapping` and transforms `module Delegate`. Surgical injection site exists. |
| User-facing Mapping module type | [`ExtensionMapping.res:110-124`](../../reventless/reventless-infra/src/types/ExtensionMapping.res#L110-L124) | `module Delegate: Reventless.Aggregate.Spec` (has `moduleUrl`). No `delegateModuleUrl` field yet — 4a adds it. |
| `ExtensionMapping.Make` functor | [`ExtensionMapping.res:199`](../../reventless/reventless-infra/src/types/ExtensionMapping.res#L199) | Runtime-safe (`extensionMappingMake`); the entry point already calls it for `PluginConnectExtension`. |
| `Util_Bundle` helpers | [`Util_Bundle.res:42,80,93`](../../reventless/reventless-aws/src/util/Util_Bundle.res#L42) | `getModuleSpecifier`, `extractPackageName`, `resolvePackageRoot` all exist. |
| PerEventCollector packageDirs pattern | [`EventCollectorRuntime_Builder_PerEventCollector.res:79-83`](../../reventless/reventless-aws/src/adapter/Runtime/EventCollectorRuntime_Builder_PerEventCollector.res#L79-L83) | Bundles 2 packages (spec + mappings). 4c mirrors with 3 (+ delegate). |
| `forPluginEventCollector` packageDirs | [`PluginRuntime_Builder.res:346-349`](../../reventless/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res#L346-L349) | `~packageDirs=Dict.make()` today; comment "No user packages — all framework imports are in the Layer" becomes obsolete after 4c. |
| `Plugin_Helpers.extensionRegistryInfo` | [`Plugin_Helpers.res:232-235`](../../reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res#L232-L235) | `{specModule, mappingsModule}` today — 4b adds `delegateModule`. |
| Entry-point placeholder | [`AdminEventCollectorEntryPoint.mjs:345-353`](../../reventless/reventless-aws/src/adapter/Runtime/AdminEventCollectorEntryPoint.mjs#L345-L353) | `console.warn("user extensions in HANDLER_CONFIG are not yet wired …")` — 4d replaces this block. |

**Path chosen for delegate URL flow: Path A** — extend the `ExtensionMapping.Mapping` module type with `let delegateModuleUrl: string`, have deploy-side capture it via first-class module unpack on each blueprint's first mapping, serialise through HANDLER_CONFIG as `extensions[*].delegateModule`. Cleanest and supports cross-package delegates.

### Step 4a — PPX exposes `Delegate.moduleUrl` (and extend `Mapping` module type)

The `@@reventless.extension` transformer at [`ReventlessPpx.ml:575-605`](../../packages/reventless-ppx/src/ppx/ReventlessPpx.ml#L575-L605) already walks `module Mapping`, opens `ReventlessInfra.ExtensionMapping`, and applies the Delegate auto-transform via `transform_delegate_module`. Two coordinated changes are needed:

**Change 1 — PPX injection.** Inside the `Pmod_structure inner` walk (line 581-591), after the inner items are mapped through, append:

```rescript
let delegateModuleUrl: string = Delegate.moduleUrl
```

The Delegate auto-transform already runs first, so `Delegate.moduleUrl` is well-defined at the point of injection. This mirrors how the file-level `let moduleUrl` is injected at line 600-603.

**Change 2 — module type extension.** Extend [`ExtensionMapping.Mapping`](../../reventless/reventless-infra/src/types/ExtensionMapping.res#L110-L124) to expose the field:

```rescript
module type Mapping = {
  module ExtensionPoint: Spec
  module Delegate: Reventless.Aggregate.Spec

  let delegateModuleUrl: string   // ← new

  let mapIncomingEvent: ...
  let mapOutgoingEvent: ...
}
```

Without this, the deploy-side `Plugin_Helpers.createExtensions` can't read `delegateModuleUrl` off the first-class `module(First.Mapping)` because it's not in the signature.

**Alternative considered:** thread the Delegate URL through `Platform.Extension.Make` into the Blueprint itself instead of routing via `Mapping`. Rejected — Blueprint already aggregates many mappings; per-mapping delegate URLs need to live on the mapping module, not the Blueprint envelope.

Rebuild both PPX binaries per `feedback_ppx_linux_rebuild`:
- macOS host: `pnpm run build:ppx` → `ppx-osx-x64.exe`.
- Linux: Docker build → `ppx-linux.exe`.
- Commit both binaries.

#### Checklist

```
Step 4a
  [ ] 4a.1  Add `let delegateModuleUrl: string` to ExtensionMapping.Mapping module type
  [ ] 4a.2  Inject `let delegateModuleUrl = Delegate.moduleUrl` inside Mapping in @@reventless.extension PPX
  [ ] 4a.3  Rebuild ppx-osx-x64.exe (host: `pnpm run build:ppx`)
  [ ] 4a.4  Rebuild ppx-linux.exe (Docker)
  [ ] 4a.5  Commit both binaries; rerun `pnpm run build` at root (zero warnings)
  [ ]       Verify: examples/online-shop-hybrid/catalog/src/Extension/Orders_Extension.res.mjs
           exports `Mapping.delegateModuleUrl` pointing at RecordProductDemand's URL
```

---

### Step 4b — Thread `moduleUrl` + `delegateModuleUrl` through Blueprint + Plugin_Helpers

**Pre-implementation finding (extends original 4b scope):** `Blueprint.Mapping` (at [`Extension.res:52`](../../reventless/reventless-infra/src/components/Extension.res#L52)) is `ExtensionMapping.T` — the *output* of `ExtensionMapping.Make`, not the user-facing `Mapping`. So Plan A's original prescription (read `M.delegateModuleUrl` by unpacking `allMappings[0]` inside `createExtensions`) doesn't typecheck — `T` doesn't carry `delegateModuleUrl`.

Worse, `Platform.Extension.Make` ([reventless-aws/src/Platform.res:400](../../reventless/reventless-aws/src/Platform.res#L400), [reventless-in-memory/src/Platform.res:517](../../reventless/reventless-in-memory/src/Platform.res#L517)) currently sets `Blueprint.moduleUrl = Mapping.Delegate.moduleUrl` — the **delegate's** URL, not the user file's URL. So `mappingsModule` in HANDLER_CONFIG today points at the delegate, not the user mapping. Harmless because user extensions aren't yet runtime-wired, but breaks Step 4d when the runtime tries to dynamic-import the user mapping.

Both issues collapse into one fix: surface user-file `moduleUrl` AND `delegateModuleUrl` from the user-facing `Mapping` through `Blueprint`, then let `Plugin_Helpers.createExtensions` read both fields off the Blueprint directly.

**Concrete changes:**

1. **PPX** (`dispatch_extension_impl`): also inject `let moduleUrl: string = <file specifier>` inside `module Mapping` (in addition to the existing file-level injection). Idempotency-safe.

2. **`ExtensionMapping.Mapping` module type** ([`ExtensionMapping.res:110`](../../reventless/reventless-infra/src/types/ExtensionMapping.res#L110)): add `let moduleUrl: string` alongside the `delegateModuleUrl` field added in 4a.

3. **`Extension.Blueprint` module type** ([`Extension.res:50-56`](../../reventless/reventless-infra/src/components/Extension.res#L50-L56)): add `let delegateModuleUrl: string`.

4. **`Platform.Extension.Make` in both adapters** ([aws:400](../../reventless/reventless-aws/src/Platform.res#L400) + [in-memory:517](../../reventless/reventless-in-memory/src/Platform.res#L517)):
   - Change `let moduleUrl = Mapping.Delegate.moduleUrl` → `let moduleUrl = Mapping.moduleUrl`.
   - Add `let delegateModuleUrl = Mapping.delegateModuleUrl`.

5. **`PluginConnectExtension_Mapping`** (hand-written inline struct, [`PluginConnectExtension_Mapping.res:167-201`](../../reventless/reventless-core/src/admin/PluginConnectExtension_Mapping.res#L167-L201)): add `let moduleUrl = "@reventlessdev/reventless-core/src/admin/PluginConnectExtension_Mapping.res.mjs"` (matches the existing `Plugin_Helpers.pluginConnectExtensionMappingsModule` constant).

6. **`Plugin_Helpers.extensionRegistryInfo`** ([line 232-235](../../reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res#L232-L235)):

```rescript
type extensionRegistryInfo = {
  specModule: string,
  mappingsModule: string,
  delegateModule: string,   // ← new
}
```

7. **`Plugin_Helpers.createExtensions`** ([line 293-299](../../reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res#L293-L299)): read both URLs off `First`:

```rescript
let registryInfo: extensionRegistryInfo = {
  specModule: Spec.moduleUrl,
  mappingsModule: First.moduleUrl,           // now the user file URL (Step 4b fix)
  delegateModule: First.delegateModuleUrl,   // new
}
```

8. **`Plugin_Helpers.extensionEntry`** ([line 126-138](../../reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res#L126-L138)): add `delegateModule: string`.

9. **`Plugin_Helpers.connect` extension-entry mapper** ([line 590-610](../../reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res#L590-L610)): propagate `delegateModule: info.delegateModule`.

Both call sites of `EventCollectorHelper.connect` ([Plugin_Builder.res:647, 666](../../reventless/reventless-core/src/components/Plugin/Plugin_Builder.res#L647-L666)) already pass `~extensionRegistryInfos` — no caller-side change needed; the new field rides along inside the record.

#### Checklist

```
Step 4b
  [ ] 4b.1  Add `let moduleUrl: string` to ExtensionMapping.Mapping module type
  [ ] 4b.2  PPX: inject `let moduleUrl = <file specifier>` inside module Mapping
            (mirrors the existing file-level injection; idempotency-safe)
  [ ] 4b.3  Add `let delegateModuleUrl: string` to Extension.Blueprint module type
  [ ] 4b.4  Fix `Platform.Extension.Make` in reventless-aws + reventless-in-memory:
              moduleUrl = Mapping.moduleUrl
              delegateModuleUrl = Mapping.delegateModuleUrl
  [ ] 4b.5  Add `let moduleUrl = "<core-internal specifier>"` to the inline
            mapping in PluginConnectExtension_Mapping.res
  [ ] 4b.6  Extend extensionRegistryInfo with `delegateModule: string`
  [ ] 4b.7  In createExtensions, populate from First.delegateModuleUrl
  [ ] 4b.8  Extend extensionEntry with `delegateModule: string`
  [ ] 4b.9  Propagate `delegateModule: info.delegateModule` in the extensions mapper
  [ ] 4b.10 Rebuild ppx-osx-x64.exe + ppx-linux.exe (Docker)
  [ ]       Verify: `pulumi preview` shows HANDLER_CONFIG.extensions[*].mappingsModule
           now points at the user Extension file (not the delegate), and
           extensions[*].delegateModule is populated separately
```

---

### Step 4c — `PluginRuntime_Builder` bundles user packages + serialises `delegateModule`

Today [`PluginRuntime_Builder.forPluginEventCollector` at line 346-349](../../reventless/reventless-aws/src/adapter/Runtime/PluginRuntime_Builder.res#L346-L349) calls `Util_Bundle.buildCodeArchive(..., ~packageDirs=Dict.make())` — only the framework entry point is in the zip. A cold-start `await import("@reventlessdev/online-shop-hybrid-catalog/.../Orders_Extension.res.mjs")` fails with `ERR_MODULE_NOT_FOUND`.

Mirror [`EventCollectorRuntime_Builder_PerEventCollector.res:79-83`](../../reventless/reventless-aws/src/adapter/Runtime/EventCollectorRuntime_Builder_PerEventCollector.res#L79-L83) but with three specs instead of two:

```rescript
let packageDirs = Dict.make()
context.extensions->Array.forEach(ext => {
  [ext.specModule, ext.mappingsModule, ext.delegateModule]
  ->Array.forEach(spec => {
    let pkgName = Util_Bundle.extractPackageName(spec)
    let pkgRoot = Util_Bundle.resolvePackageRoot(pkgName)
    packageDirs->Dict.set(pkgName, pkgRoot)
  })
})
```

Replace the existing `~packageDirs=Dict.make()` with `~packageDirs`. Update the "No user packages …" comment at line 345.

Add the new `delegateModule` field to the HANDLER_CONFIG JSON template emitted in the same builder (the JSON assembly preceding line 341's `JSON.Encode.object(dict)->JSON.stringify`).

#### Checklist

```
Step 4c
  [ ] 4c.1  Build packageDirs from per-extension specModule + mappingsModule + delegateModule
  [ ] 4c.2  Pass `~packageDirs` to `Util_Bundle.buildCodeArchive` in `forPluginEventCollector`
  [ ] 4c.3  Update the line-345 comment ("No user packages …")
  [ ] 4c.4  Add `delegateModule` to the HANDLER_CONFIG JSON template
  [ ]       Verify: CatalogPluginEventColl asset zip contains catalog's plugin package
           (file count > framework-only baseline; check via `unzip -l`)
  [ ]       Verify: `pulumi preview` shows HANDLER_CONFIG.extensions[*].delegateModule
           populated end-to-end
```

---

### Step 4d — Entry-point three-import reconstruction + real Ops wiring

File: [`AdminEventCollectorEntryPoint.mjs`](../../reventless/reventless-aws/src/adapter/Runtime/AdminEventCollectorEntryPoint.mjs). The placeholder block to replace is at [lines 345-353](../../reventless/reventless-aws/src/adapter/Runtime/AdminEventCollectorEntryPoint.mjs#L345-L353):

```js
// User-declared extensions — HANDLER_CONFIG now carries the metadata
// (specModule / mappingsModule / extensionPointName / aggregateNames /
// readModelNames) but the runtime reconstruction is deferred to a follow-up.
if (config.extensions.length > 0) {
  console.warn("AdminEventCollectorEntryPoint: user extensions in HANDLER_CONFIG are not yet wired; …");
}
```

Replace with a loop performing three dynamic imports per extension, reconstructing the `Mapping` object, and building real per-extension Ops:

```js
// 1. Three dynamic imports
const userMod     = await import(ext.mappingsModule);
const userMapping = userMod.Mapping;
const epSpec      = patchSpecId(await import(ext.specModule));
const delegateSpec = await import(ext.delegateModule);

// 2. Reconstruct the full mapping (ReScript erases ExtensionPoint/Delegate from the .res.mjs export)
const fullMapping = {
  ExtensionPoint: epSpec,
  Delegate: delegateSpec,
  mapIncomingEvent: userMapping.mapIncomingEvent,
  mapOutgoingEvent: userMapping.mapOutgoingEvent,
};
const transformedMapping = extensionMappingMake(fullMapping);
const mappingsModule = { Spec: epSpec, name: ext.name, mappings: [transformedMapping] };

// 3. Per-extension publishToAggregates (filtered to ext.aggregateNames)
const extPublishToAggregates = {};
for (const aggName of ext.aggregateNames) {
  const envVar = config.publishToAggregates[aggName];  // "PTA_<agg>_QUEUE_URL"
  const queueUrl = envVar && process.env[envVar];
  if (!queueUrl) continue;
  extPublishToAggregates[aggName] = sqsPublishJsons(makeQueueRef(queueUrl), "SQS_FIFO");
}

// 4. Per-extension publishToReadModels (uses PRM_<rm>_QUEUE_URL env vars from Step 3b)
const extPublishToReadModels = {};
for (const rmName of ext.readModelNames) {
  const envVar = config.readModelQueueUrls[rmName];  // "PRM_<rm>_QUEUE_URL"
  const queueUrl = envVar && process.env[envVar];
  if (!queueUrl) continue;
  extPublishToReadModels[rmName] = sqsPublishJsons(makeQueueRef(queueUrl), "SQS_FIFO");
}

// 5. readModelNamesForSourceName (admin's deploy-side dict, scoped to this EP)
const extReadModelNamesForSourceName = {
  [ext.extensionPointName]:
    config.readModelNamesForSourceName?.[ext.extensionPointName] || [],
};

// 6. Construct Ops
const ops = extensionOperationsMake(epSpec)(mappingsModule)({
  publishToAggregates: extPublishToAggregates,
  publishToPluginExtensionPoint: sqsPublishJsons(
    makeQueueRef(config.pluginExtensionPointCmdTopicUrl), "SQS_FIFO"),
  readModelNamesForSourceName: extReadModelNamesForSourceName,
  publishToReadModels: extPublishToReadModels,
  queryEngine,
});

// 7. Register handlers
incomingExtensionEventHandlers[ext.extensionPointName] = ops.handleIncoming;
for (const aggName of ext.aggregateNames) {
  outgoingExtensionEventHandlers[aggName] = ops.handleOutgoing;
}
```

`extensionMappingMake` lives at `@reventlessdev/reventless-infra/src/types/ExtensionMapping.res.mjs` — runtime-safe (only depends on sury + reventless-spec).

#### Checklist

```
Step 4d
  [ ] 4d.1  Add the three-import block (specModule, delegateModule, mappingsModule)
  [ ] 4d.2  Reconstruct fullMapping; call extensionMappingMake
  [ ] 4d.3  Build extPublishToAggregates from PTA_<agg>_QUEUE_URL env vars
  [ ] 4d.4  Build extPublishToReadModels from PRM_<rm>_QUEUE_URL env vars
  [ ] 4d.5  Wire readModelNamesForSourceName from HANDLER_CONFIG
  [ ] 4d.6  Register handlers in incomingExtensionEventHandlers / outgoingExtensionEventHandlers
  [ ]       Verify: CatalogPluginEventColl cold-starts cleanly; logs show
           "Loaded extension Orders_Extension (EP: Ordering.Orders, delegate: RecordProductDemand)"
  [ ]       Verify: a user-extension whose mapIncomingEvent emits
           `PublishAggregateCommand("RecordProductDemand", cmd)` successfully delivers to
           the RecordProductDemand command queue
```

---

### Step 4e — Subscription bootstrap

**Pre-implementation scope finding (2026-05-18):** the example deploys via two different modes with very different cross-plugin EP-discovery costs, and one of them is **already wired**:

| Mode | Where | Cross-plugin EP discovery |
|---|---|---|
| **In-memory monolithic** | `platform-in-memory/src/Main.res` via `Platform.makePlatform([...])` | **Already wired** — see [`Platform.res:1281-1297`](../../reventless/reventless-in-memory/src/Platform.res#L1281-L1297). After all plugins are built, walks each plugin's `extensions` outputs and calls `Bus.subscribeEventCollectorToTopic(eventCollectorName, epTopicKey)` where `epTopicKey = extensionPointName.replace(".", "") ++ "ExtPointEventTopic"`. Combined with 4a–4d, this is the in-memory end-to-end path. |
| **AWS split-stack** | `*-aws/src/Main.res` via `Platform.deployPlugin(...)` | Each plugin in its own Pulumi stack — needs arbitrary peer-plugin `StackReference`s (the existing `Interstack.coreStackReference` only covers the core/admin stack). Multi-day infrastructure work, properly belongs to the [cross-plugin rewire plan](./plugin-eventcollector-runtime-rewire-cross-plugin.md). |

The original plan sketch (add a `pluginExtensionPoints` hook, accumulate EPs in `makePlatform`, read in `Plugin_Builder`, populate `eventTopics`) is redundant for in-memory — the simpler post-hoc Bus subscription already covers the same outcome.

**For Step 5 (alpha verification on AWS): blocked by the cross-plugin rewire plan.** What this plan delivers without that: a working local E2E where catalog's `Orders_Extension` receives `ItemOrdered` from ordering's `Orders_ExtensionPoint` and writes to `ProductDemands`.

#### Checklist

```
Step 4e
  [x] 4e.1  In-memory cross-plugin subscription — already wired via
            Bus.subscribeEventCollectorToTopic in Platform.res:1281-1297.
            Topic key derivation: extensionPointName.replace(".", "") ++ "ExtPointEventTopic".
  [x]       Verify (manual, 2026-05-18): online-shop-hybrid platform-in-memory
            boot OK; mutation `Ordering_PlaceOrder` accepted; server logs show
            full chain:
              [Ordering][ExtensionPoint(Ordering.Orders)] mapped → ItemOrdered(prod-A/B)
              [Catalog][Plugin] incoming event: ItemOrdered(prod-A/B)         ← cross-plugin sub
              [Catalog][Extension(Ordering.Orders.Catalog)] EP→RecordProductDemand: RecordDemand(prod-A/B)   ← 4d dispatch
              [Catalog][StateChangeSlice(RecordProductDemand)] produced ProductDemandRecorded
              [Catalog][StateViewSlice(ProductDemand)] handled the event
            The cross-plugin runtime path works end-to-end. The GraphQL
            `Catalog_ProductDemands` query returns empty because the projection
            uses Update instead of UpdateWithDefault for first writes — that's
            an example-plugin bug, not a framework / runtime-rewire issue.
  [ ] 4e.2  (Deferred to cross-plugin plan) AWS deployPlugin cross-stack EP
            discovery — arbitrary peer-plugin StackReferences; not addressed here.
```

---

## Step 5 — Live verification with online-shop-hybrid

The hybrid example already has user-declared extensions (`Orders_Extension` in catalog, `Products_Extension` in ordering). It's the natural end-to-end test.

Verification sequence:

1. Deploy online-shop-hybrid to the alpha stack (or rebuild + manually patch layer as we've been doing).
2. Place an order via the AppSync API (`mutation Place(…)`).
3. Order aggregate emits `Placed` → admin's EventColl maps to `ItemOrdered` events published to Ordering's `Orders_ExtensionPoint` EventTopic.
4. Catalog's `CatalogPluginEventColl` is subscribed to that EventTopic (assumes minimal plan's cross-plugin subscribe step is done OR admin pre-wires the subscription). Receives `ItemOrdered`.
5. `Orders_Extension.mapIncomingEvent` returns `[PublishStateChangeSliceCommand(RecordDemand(…))]` → entry point's `applyIncomingCommandAction` calls `extPublishToAggregates["RecordProductDemand"](…)`.
6. RecordProductDemand slice processes the command → emits domain event → `ProductDemands` RM enqueues via `extPublishToReadModels["ProductDemands"]` → row appears in `ProductDemands-<hash>` table.

Each step has CloudWatch logs to assert against; the final `aws dynamodb scan --table-name ProductDemands-<hash>` is the success criterion.

### Checklist

```
Step 5
  [ ] 5.1  Trigger Place order via AppSync (or admin's mutation handler)
  [ ] 5.2  Order aggregate's EventLog has the Placed event (DynamoDB scan)
  [ ] 5.3  CatalogPluginEventColl logs "incoming event: ItemOrdered" + "EP→RecordProductDemand: RecordDemand"
  [ ] 5.4  RecordProductDemand slice's lambda receives the command (log group exists, processes it)
  [ ] 5.5  ProductDemands RM table has a row for the ordered productId
  [ ]      Verify: full cross-plugin extension chain is functional on alpha
```

---

## Honest concerns / unresolved

1. **`readModelNamesForSourceName` is a deploy-time inversion.** Today it's built from each read model's `subscribeTo` (or equivalent) field, inverted to `sourceName → [rmName]`. The entry point needs the inverted dict; computing it deploy-side is straightforward but a code path that doesn't exist for the bundled-Lambda model yet. Worth a small refactor that exposes the existing computation as a helper.

2. **The `extPublishToReadModels` enqueue mechanism.** Today, RM event delivery happens via SQS/DDB-stream subscriptions established deploy-side; the Extension's runtime `enqueueEvent` is provided as a closure that publishes to the relevant SQS queue or invokes the RM's processing lambda. The bundled handler needs to reconstruct that closure from a queue URL or table name. Concrete check: which channel does `EventCollector_Builder` pick for an RM? If SQS, we already have `sqsPublishJsons`; if DynamoDB stream, this gets harder (you can't synthesise stream events runtime-side — would need a different routing strategy, e.g. publish to an intermediate SQS).

3. **Multi-extension-per-EP merging.** Option (ii) in Step 2 (entry-point-side grouping) is simpler but means each Extension's `aggregateNames` / `readModelNames` need to be merged when building Ops — otherwise the Ops dict is the union but `extensionPointName` keys collide. Solvable but worth thinking through with a test case (two `*_Extension.res` files in `catalog/src/Extension/` both targeting `Ordering.Orders`).

4. **Subscription bootstrap.** Even with Step 5's full chain wired, the catalog plugin only receives `ItemOrdered` events if its EventColl SQS is subscribed to Ordering's `Orders_ExtensionPoint` EventTopic. Today that subscription happens via `Spec.runtimeOps.topicSubscription.subscribeChannelToTopic` invoked from the `DoConnectPlugin` callHandler — which is the cross-plugin path explicitly deferred in the minimal plan. For Step 5 to work without the cross-plugin path, the admin must pre-create subscriptions at deploy time (already happens for some EventTopics? confirm by looking at the SNS subscription list for an existing EP topic). If deploy-time pre-subscription already covers this, great; if not, this becomes a soft prereq for verification.

## Phasing recommendation

Don't combine this plan with the minimal one in a single PR. Ship the minimal plan first (smaller blast radius, easier to verify, gets Plugin RM populated which is the user-visible deliverable). Land this plan as a follow-up once the minimal one is stable.

The cross-plugin subscribe path (currently out of scope of both plans) becomes Phase 3 — a third plan documenting how peer-plugin EP outputs flow into HANDLER_CONFIG and how the runtime maintains SNS subscriptions reactively.

## References

- [Plugin_Helpers.connect (deploy-side wiring)](../../reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res#L304) — current source of truth for the merged-per-EP Extension list, `publishToAggregates`, `publishToReadModels`
- [Extension_Operations.Make](../../reventless/reventless-core/src/components/Extension/Extension_Operations.res#L24) — the runtime constructor the entry point will call per merged extension group
- [Plugin_Callback.Make](../../reventless/reventless-core/src/components/Plugin/Plugin_Callback.res#L16) — service-name-keyed dispatch (already wired by the minimal plan)
- `examples/online-shop-hybrid/catalog/src/Extension/Orders_Extension.res` — the example that will be the verification fixture
- The minimal plan: [plugin-eventcollector-runtime-rewire.md](./plugin-eventcollector-runtime-rewire.md)
