# EventCollector `publishToAggregates` SendMessage grant — never created; DCB URL is a nested-option sentinel — Analysis

**Date**: 2026-07-14 (resolved same day)
**Scope**: deploy-time IAM bug that prevents a cross-plugin **Extension → DCB StateChangeSlice** command publish. On the deployed `online-shop-hybrid` example, this made **Place Order** fail with *"These products aren't available yet: Prod 1."* Two distinct root causes.
**Status**: **RESOLVED** — fix implemented in `Dcb_Builder.res` + `PluginRuntime_Builder.res` (+ heartbeat runner) and E2E-validated on alpha (eu-west-1): grants live on both plugin collectors, product-add → cross-plugin sync → place-order verified working end-to-end. See § Resolution and § Follow-ups.
**Related**: [[feedback_option_proxy]] convention (never wrap a Pulumi Output in a ReScript `option`) — this bug is that anti-pattern manifesting. Memory: `reference_ec_publish_to_aggregates_grant_broken`.

---

## Symptom

In the deployed hybrid shop UI, opening **Ordering → Place Order** for a catalog product shows:

```
These products aren't available yet: Prod 1.
```

The product exists in the Catalog plugin (visible in `Catalog → Products`) but never propagates to the Ordering plugin's `AvailableProducts` read model, so `PlaceOrder` rejects it.

CloudWatch confirms the break (eu-west-1):

```
# OrderingPluginEventColl-72fd3f4
level=ERROR  Error on publish command to aggregate SyncCatalogProduct:
  User: …/OrderingPluginEventColl-72fd3f4 is not authorized to perform:
  sqs:sendmessage on resource: …:OrderingDcbCmdTopic-01908ac
  because no identity-based policy allows the sqs:sendmessage action
  comp: Extension(Catalog.Products.Catalog.Products.Ordering)

# OrderingDcbCmdHandler-2007759  (two minutes later)
level=ERROR  decide rejected: ProductsNotAvailable {"missing":["1f219c65-…-3200265c4367"]}
  comp: StateChangeSlice(PlaceOrder)
```

## The intended propagation path (all wiring is correct)

```
catalog AddProduct
  → ProductAdded (catalog DCB event log)
  → Products_ExtensionPointMapping.mapOutgoingEvent
      → PublishEvent(ProductBecameAvailable)               [CatalogSpec.Products_ExtensionPoint]
  → ordering Products_Extension.Mapping.mapIncomingEvent
      → PublishStateChangeSliceCommand(SyncNewProduct)     [Delegate = SyncCatalogProduct]
  → SyncCatalogProduct slice: decide → CatalogProductSynced
  → AvailableProducts_Projection: Set(productId, …)        [ordering read model]
  → PlaceOrder_Behavior.evolve: availableProductIds += productId
```

Every ReScript file in this chain is correct. The `Products_Extension` **does** run (inside the Ordering `EventCollector` Lambda) and **does** produce the `SyncNewProduct` command. The failure is purely that the Lambda's execution role cannot `sqs:SendMessage` to the DCB command-topic FIFO queue (`OrderingDcbCmdTopic`). So the command is dropped, `CatalogProductSynced` is never emitted, and `AvailableProducts` stays empty.

## Root cause 1 — the grant `RolePolicy` is created inside a `Pulumi.Output.apply` and never registers

File: `reventless/reventless-aws/src/plugin/runtime/PluginRuntime_Builder.res`, `forPluginEventCollector`.

The block that grants the collector `sqs:SendMessage` on the command-topic queues its extensions publish to (`sid: AllowEcPublishToAggregateCmdTopics`, RolePolicy `${name}-publishToAggregates`) builds the policy document in an apply **and calls `PulumiAws.IAM.RolePolicy.make` inside that apply's callback**:

```rescript
let policyJsonOutput =
  queueUrlOutputs->Pulumi.Output.all->Pulumi.Output.apply(urls => { … Some(json) | None })
let _ =
  policyJsonOutput->Pulumi.Output.apply(policyOpt =>
    switch policyOpt {
    | Some(policyJson) =>
      let _ = PulumiAws.IAM.RolePolicy.make(~name=`${name}-publishToAggregates`, ~args={…})  // ← inside apply
    | None => ()
    })
```

Creating a resource inside a `Pulumi.Output.apply` callback is a documented Pulumi anti-pattern — the resource is not reliably registered with the engine. **Verified**: a scan of every `*EventColl*` role in the alpha account found the `AllowEcPublishToAggregateCmdTopics` / `-publishToAggregates` policy on **zero** roles. This grant has never been created for any collector (DCB or aggregate) since it was introduced (commit `45dca0437`).

The correct pattern is used a few blocks up in the same file for `pluginRmScan`: build the policy JSON in an apply, then call `RolePolicy.make` **at top level** with `policy: policyJson->Pulumi.Output.asInput`.

**Verified fix for this half:** moving `RolePolicy.make` to top level does create the resource — a `pulumi up` on alpha produced `+ aws:iam:RolePolicy OrderingPluginEventColl-publishToAggregates created`.

## Root cause 2 — the DCB command-topic URL arrives as a nested-option sentinel

Even with the RolePolicy created, its `Resource` resolved to a placeholder, because the URL never resolves to a real ARN.

Origin: `reventless/reventless-core/src/components/Dcb/Dcb_Builder.res`, field `dcbCommandTopicQueueUrl: option<Pulumi.Output.t<string>>`, computed as:

```rescript
let dcbCommandTopicQueueUrl = {
  let outputs: CommandTopic.outputs = dcbCommandTopic->Component.outputs->Obj.magic
  switch outputs.resources->Array.get(0) {
  | Some(r) => Some(r.id)   // r.id read synchronously, before the topic constructs
  | None => None
  }
}
```

`Component.outputs` reads a WeakMap that the topic's Pulumi `construct` callback (which creates the SQS queue and calls `setOutputs`) has **not populated yet** at this point. So `r.id` is `undefined`, and `Some(undefined)` compiles to the nested-option sentinel `{ BS_PRIVATE_NESTED_SOME_NONE: 0 }`. This is precisely the `option<Pulumi.Output.t<'a>>` combination CLAUDE.md forbids.

That sentinel flows `dcbCommandTopicQueueUrl → aggregateQueueUrls[sliceName] → mergedAggregateUrls → context.publishToAggregates[sliceName]`.

**Verified ground truth** (crash-proof `%raw` probe, inside `forPluginEventCollector`):

```
[DBG] OrderingPluginEventColl  SyncCatalogProduct:
      hasApply=false  isInstance=false  typeof=object  val={ BS_PRIVATE_NESTED_SOME_NONE: 0 }
```

So at grant-build time the value is a plain sentinel object — not a Pulumi Output. In the grant path it is dropped by the `typeof(url) === #string` filter → empty ARN list → placeholder policy. (In a crashing variant, `o->Pulumi.Output.apply` throws `o.apply is not a function` because the sentinel has no `.apply`.)

### Unexplained but important observation

The **runtime** unmistakably has the correct URL: the IAM error names the real `OrderingDcbCmdTopic-01908ac`, and the deployed collector Lambda's env var `PTA_SyncCatalogProduct_QUEUE_URL` was observed as the real queue URL. The runtime env-var path (`queueUrlOutput->Pulumi.Output.asInput`, resolved by Pulumi at Lambda-creation time) yields the real URL, while the grant path (synchronous read inside `Plugin_Helpers` `applyHelperAsync`) yields the sentinel — **same `context.publishToAggregates`, different resolution**. The exact mechanism of this divergence was not fully pinned down. Practically: only the *deploy-time grant computation* is broken; the runtime dispatch URL is fine.

## Approaches attempted (none fully worked)

| Attempt | Result |
|---|---|
| Gate the `Dcb_Builder` read on `Component.operations->Pulumi.Output.flatMap(…)` (resolve after construct) | Value resolves to the real URL under a *direct* `.apply` (proven), but `Pulumi.Output.all` in the grant still collapses it to the sentinel; downstream it compiled to `Some(undefined)` again. |
| Defer the read via a thunk invoked inside `Plugin_Builder`'s resolved apply | Reads too early — that apply is not gated on the DCB command topic's construction, so `r.id` is still the sentinel. |
| Source the URL from `AutomationSliceRuntime_Builder_Single.getDcbQueueUrl()` (the clean `channelParts.queue.id` captured by the `onDcbCommandTopicCreated` hook) | Returns `None` at collector-build time — the hook fires too late relative to `forPluginEventCollector`. |
| Move `RolePolicy.make` to top level (root cause 1 fix) | Works — resource is created — but resolves the placeholder ARN because of root cause 2. |
| Pre-flatten each output via its own `.apply` before `Pulumi.Output.all` | `o.apply is not a function` (the value is the sentinel plain object, not an Output). |

## Recommended fix

Address both causes together:

1. **Create the RolePolicy at top level**, mirroring the `pluginRmScan` grant: build `policyJson: Output<string>` in an apply, then call `RolePolicy.make(~args={policy: policyJson->asInput, …})` unconditionally when there are extension targets (emit a valid placeholder resource when the resolved ARN list is empty, since IAM rejects an empty `Resource` array).
2. **Source the DCB command-topic ARN from a clean, correctly-timed Output** — most promisingly `channelParts.queue.arn` (or `.id` → ARN), which the AWS `onDcbCommandTopicCreated` hook already captures cleanly (`Platform.res`, `setDcbQueueUrl`). This likely means either deferring the grant to a point where that Output is available, or threading the queue ARN into the collector's `eventCollectorContext` alongside `publishToAggregates` rather than reading it back through the sentinel-valued dict.

The deeper structural fix for root cause 2 is to stop surfacing `dcbCommandTopicQueueUrl` as `option<Pulumi.Output.t<string>>` read synchronously off `Component.outputs`, and instead thread a genuine, post-construction Output (per [[feedback_option_proxy]]).

## Reproduction / verification notes

- Deploy target: `examples/online-shop-hybrid/ordering-aws`, stack `alpha`, region eu-west-1. Local `pulumi preview`/`up` picks up workspace edits to `reventless-core`/`reventless-aws` via pnpm symlinks; pass `REVENTLESS_COGNITO_USER_POOL_ID` (inert for the plugin stack — it reads auth from the platform stack reference).
- Preview matched `up` for the sentinel/placeholder outcome, but **cannot** confirm the grant resource itself while it is created inside an apply (resources created inside `apply` do not preview reliably) — validation of root cause 1 required an actual `up` + inspecting the role's inline policies.
- Check the grant with: `aws iam list-role-policies --role-name <collectorRole>` then `get-role-policy … --policy-name …-pta-<SliceName>`.

## Resolution (2026-07-14)

Three coordinated changes:

1. **`Dcb_Builder.res`** — `dcbCommandTopicQueueUrl` is no longer `option<Pulumi.Output.t<string>>` (the forbidden combination) but a plain `Pulumi.Output.t<string>` resolving to `""` for plugins without DCB slices. The URL read is gated on `Component.operations` (an Output that resolves only after the topic's construct stored real resources), instead of the timing-fragile synchronous `resources[0].id` read. `Plugin_Builder.res`'s consumer switch became an unconditional per-slice `Dict.set`.
2. **`PluginRuntime_Builder.res` (reventless-aws)** — the grant is now **one RolePolicy per extension target** (`${name}-pta-${aggName}`, sid `AllowEcPublishToAggregateCmdTopic`), each policy JSON derived through a **single `.apply`** on that target's queue-URL Output, and `RolePolicy.make` is called at **top level** (not inside an apply). `Pulumi.Output.all` was eliminated from this path entirely: empirically (probes in the same program run), a direct `.apply` on the operations-gated Output delivered the real URL while `pulumi.all` over the very same Output array resolved to the nested-option sentinel — root cause of that divergence remains unexplained, so the fix simply avoids `all` here. Dict values are runtime-heterogeneous (plain resolved strings for aggregates, Outputs for DCB slices); both are handled, anything else is skipped.
3. **`StateViewSliceEntryPoint.mjs`** — completed an in-flight `~comp=` signature change on `Projection.handleAction`: the hand-written entry point now passes `(specModule.name, action, ops, subIdConfig)` positionally. (Without this, every state-view projection crashed with `undefined.saveBatch` — an unrelated breakage surfaced during validation because workspace state ships in local deploys.)

**E2E validation on alpha** (all verified live):
- IAM: `OrderingPluginEventColl-pta-SyncCatalogProduct → arn:aws:sqs:…:OrderingDcbCmdTopic-01908ac` and `CatalogPluginEventColl-pta-RecordProductDemand → …:CatalogDcbCmdTopic-cd2d834`.
- Flow: `Catalog_AddProduct` (CommandAccepted) → collector log `EP→SyncCatalogProduct: SyncNewProduct(…)` with **no AccessDenied** → `CatalogProductSynced` in `OrderingDcbEventLog` → `AvailableProducts` row projected → `Ordering_PlaceOrder` → **CommandAccepted**, `Orders` row `status: Placed`.
- Auth for the E2E run: temporary Cognito user (`e2e-verify`), deleted afterwards.

## Follow-ups (addressed 2026-07-14)

### Heartbeat grant — same anti-pattern, now fixed

`HeartbeatRunner_CloudWatchEvents.res` created its `AllowLambdaToSendSQS` RolePolicy (grant on `CorePluginExtPointCmdTopic`) **inside** a `Pulumi.Output.apply` — the same non-registration anti-pattern. It intermittently left `CatalogPluginHeartbeat` without the grant (observed AccessDenied at 08:46 on the CI deploy; self-healed on a later `up`). Fixed by creating the RolePolicy at **top level**: `coreSqsQueue.urn` is an already-resolved ARN string from the `resolvedResource` remote channel and `lambdaRole.id` is an Output, so neither needs an apply; the Lambda `Permission` + CloudWatch `EventTarget` (which genuinely need the resolved Lambda arn/name) stay in an apply. Verified on catalog-aws: grant present with the correct ARN, heartbeat invocation clean.

### The `pulumi.all`-vs-`.apply` divergence — characterized

Reproduced with the current (option-free) source, in one preview run: `Pulumi.Output.all([o])` resolved the DCB URL Output `o` to the `{BS_PRIVATE_NESTED_SOME_NONE: 0}` sentinel, while a direct `o->apply(f)` was correctly treated as unknown-until-`up` (and on `up` resolves to the real URL). Root of it: `flatMap`/`map`/`unwrap` are **all just `.apply`** at runtime (the `%identity` unwrap is compiled away), so there is no literal nested `Output<Output>`. The fragility is specific to how `dcbCommandTopicQueueUrl` is built — `Component.operations->apply(_ops => Component.outputs.resources[0].id)` **ignores the `operations` payload and reads `Component.outputs` as a synchronous side channel inside the callback**, gated on `operations` only for timing. `Pulumi.Output.all` schedules that callback at a different point in the resolution graph than a direct `.apply`, where the side-channel read still returns the sentinel. **Rule: a value built from a gated side-channel read must be consumed with a direct per-item `.apply`, never batched through `Pulumi.Output.all`/`all2`.** Audit result: the other lifted-output builders (`Plugin_Helpers` `extractExtensionPointDefinitions`, `extensionPointEntries`) use the *clean* pattern — `topicOutput->flatMap(({resources}) => resources[0].id)`, where the id flows through the output's own resolved payload — and work correctly through `all2`; the EC grant was the only consumer of the fragile side-channel output through `all`, and it is fixed.

## Still open

- Pre-existing `option<Pulumi.Output.t<…>>` fields elsewhere (`dcbPublishJsons`, `adminConfig` in `PluginRuntime_Builder`, `heartbeatConfig.epQueueUrl`) still violate the [[feedback_option_proxy]] convention and should be migrated opportunistically.
- A cleaner long-term fix for `dcbCommandTopicQueueUrl` would surface a genuine `Output<{resources}>` payload for the DCB command topic (like the extension-point path) so the URL flows through the output rather than a gated side-channel read — removing the "must not batch through `all`" constraint entirely.
