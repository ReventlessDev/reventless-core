# Plan: Plugin EventCollector runtime rewire — cross-plugin subscriptions (Phase 3)

## Status

Third in a series. Prerequisites:
- [Phase 1 — minimal](./plugin-eventcollector-runtime-rewire.md) (Connect round-trip; Plugin RM populates)
- [Phase 2 — generic](./plugin-eventcollector-runtime-rewire-generic.md) (user extensions; plugin-local RMs)

This plan completes the loop by making cross-plugin event routing actually work at runtime: when plugin A's `Orders_Extension` is interested in events from plugin B's `Orders_ExtensionPoint`, plugin A's `EventCollector` SQS queue must be subscribed to plugin B's SNS EventTopic. Today's `PluginConnectExtension_Builder` was designed for this — `DoConnectPlugin` directive invokes `Spec.runtimeOps.topicSubscription.subscribeChannelToTopic` — but the bundled-Lambda entry points stub `subscribeChannelToTopic` as `async () => {}` (see [PluginExtensionPointEntryPoint.mjs:49](../../reventless/reventless-aws/src/adapter/Runtime/PluginExtensionPointEntryPoint.mjs#L49), [AdminEventCollectorEntryPoint.mjs:57](../../reventless/reventless-aws/src/adapter/Runtime/AdminEventCollectorEntryPoint.mjs#L57)). The actual AWS implementation already exists at [Util_TopicSubscription_Runtime](../../reventless/reventless-aws/src/util/Util_TopicSubscription_Runtime.res) — it just isn't wired.

## Problem

Even after Phases 1 + 2:

1. Plugin A's `Orders_Extension` is in HANDLER_CONFIG with the right `extensionPointName: "Ordering.Orders"`.
2. Plugin A's `Extension_Operations.Make` is wired into `Plugin_Callback.Make` and ready to dispatch on incoming `ItemOrdered` events.
3. **But** no `ItemOrdered` event ever lands in plugin A's EventCollector SQS queue, because there's no SNS subscription from plugin B's `Orders_ExtensionPoint` EventTopic to plugin A's queue.

The deploy-time wiring stops at "each plugin's EventCollector queue has a policy allowing peer SNS topics to send to it" — the actual subscriptions are intended to be created at runtime when `Connected(peer)` events fire. That wiring is dead code today.

## Architectural choice — where do subscriptions live?

Three approaches. The plan is structured around **option B (admin-mediated)** as the recommended path; A and C are described for context.

### Option A — Pure runtime, per-plugin (the original design)

Each plugin's EventCollector reacts to `Connected(peer)` events via `PluginConnectExtension`'s `DoConnectPlugin` callHandler. The callHandler runs `subscribeChannelToTopic(myEventCollQueue, peerEventTopic)` for every peer EP this plugin's extensions target.

**Pros**:
- Matches existing code structure (PluginConnectExtension is built for this)
- Late binding — peer plugins can join at any time
- No central coordinator

**Cons**:
- IAM sprawl: every plugin Lambda role needs `sns:Subscribe`/`Unsubscribe`/`ListSubscriptionsByTopic` permissions on cross-plugin EP topics (potentially wildcarded across the account)
- Plugin EventColl needs to bootstrap on cold start: scan Plugin RM for already-Connected peers and create missing subscriptions
- Two-way race: A connects first → no peers visible. B connects later → A receives Connected(B) eventually → subscribes. But events B published between B's Connect and A's subscription are LOST
- Subscription state tracking: avoid duplicate Subscribe calls per restart; need to list-then-create or store the SubscriptionArn somewhere
- Each plugin's bundled HANDLER_CONFIG needs an `extensions[].targetExtensionPointName → peerTopicArn` resolver — but peer topic ARN is unknown until the peer plugin's Connect arrives, so subscription creation must be lazy

### Option B — Admin-mediated (RECOMMENDED)

The admin already processes every `Connect` command (the Plugin aggregate emits `Connected` from it). The `Connected` event payload IS the full `pluginDefinition` — including this plugin's `extensionPoints[]` (what it offers) AND `extensions[]` (what it consumes). The admin has the full topology in hand at every Connect.

When admin processes `Connected(pluginX)`:
- For each `extension` in pluginX's definition: look up the EP it targets in the Plugin RM (or in the current state); create SNS subscription `peerEPTopic → pluginX.eventCollector`.
- For each `extensionPoint` in pluginX's definition: scan all other connected plugins' extensions; create subscriptions for those targeting this EP.

The admin already runs `mkUpdateApiSchema` on Connect (Phase 1 inherited this) — same pattern, just adds subscription management to the same async hook.

**Pros**:
- Single source of truth for the subscription topology
- Single IAM role (admin's) needs the broad `sns:Subscribe`/`Unsubscribe`/`ListSubscriptionsByTopic` perms; plugin roles stay narrow
- Atomic update: per Connect, admin does ONE pass to wire all relevant subscriptions
- Easier debugging (one log group to inspect; one place to query "what subscriptions exist for plugin X")
- No race window — subscriptions land in the same RM-update cycle as the Connect itself
- Plugin EventColl code stays simple (no SNS SDK calls, no cold-start bootstrap, no subscription tracking)

**Cons**:
- Admin becomes a coordination point; bug in admin = no subscriptions
- Admin needs to handle subscription churn on Disconnect/Deactivate too (already getting Disconnect events; just adds Unsubscribe calls)
- Cold-start of admin needs to reconcile (scan Plugin RM, list existing subscriptions, fill gaps) — but only on admin, not per-plugin

### Option C — Deploy-time pre-subscription

At deploy time, the platform builder knows every plugin in the stack. It creates all subscriptions statically.

**Pros**:
- Simplest. No runtime SDK calls. No IAM beyond deploy-time roles.
- Pulumi state mirrors the actual SNS subscriptions; easy to reason about.

**Cons**:
- Kills the "plugins connect at runtime / via separate deploys" model that the framework is designed around
- Requires every plugin to be known at deploy time of every other plugin
- Adding a new plugin requires redeploying ALL plugins (or at least the admin)
- Doesn't match the existing Plugin/Connect/Disconnect aggregate design at all
- Effectively a regression of the framework's late-binding capabilities

### Recommendation

**Option B**. It preserves the late-binding model (plugins can deploy independently and connect at runtime), centralises the cross-plugin coordination in the admin (which already has every piece of information at Connect time), and removes the IAM sprawl + cold-start bootstrap complexity of Option A. The existing `PluginConnectExtension_Builder.callHandler` becomes vestigial; we either repurpose it as a no-op (since admin now owns subscription management) or remove it entirely.

The rest of this plan assumes Option B.

---

## Step 1 — Move subscription management from plugin runtime to admin

Files:
- `reventless/reventless-core/src/admin/PluginExtensionPoint_Plugin.res` — already has `DoConnectPlugin` / `DoDisconnectPlugin` handler dispatching to `Spec.updateApiSchema`. Add a parallel `Spec.manageSubscriptions` hook (or extend `updateApiSchema` into a more generic `onConnect`/`onDisconnect` pair).
- `reventless/reventless-aws/src/adapter/Runtime/AdminEventCollectorEntryPoint.mjs` — implement the new hook.

New AdminEventColl HANDLER_CONFIG fields:
```json
"plugins": [
  {
    "id": "Catalog@1.0.0-alpha.44",
    "name": "Catalog",
    "extensionPoints": [
      { "name": "Catalog.Products", "eventTopicArn": "arn:aws:sns:…:CatalogProductsEventTopic-…" }
    ]
  },
  // …other plugins, fetched from Plugin RM scan at cold start
],
"snsSubscribeRoleArn": "arn:aws:iam::…:role/AdminEventColl-…"
```

Actually — `plugins[]` should NOT be in HANDLER_CONFIG (would require admin redeploy every time a plugin joins). Instead, the admin Lambda scans the Plugin RM table at startup AND on each Connect to get current state. The new HANDLER_CONFIG field is just:
```json
"pluginReadModelTableName": "Plugin-<hash>"  // already present
```

Plus IAM updates (Step 2).

The new `manageSubscriptions(pluginDefinition, action: "connect" | "disconnect")` hook in the admin entry point:

```js
async function manageSubscriptions(pluginDef, action) {
  // pluginDef carries this plugin's EPs (what it offers) + extensions (what it consumes).
  // Other plugins are read from the Plugin RM table.
  const allPlugins = await scanPluginRm(config.pluginReadModelTableName);

  if (action === "connect") {
    // For each extension on the connecting plugin: find peer EP and subscribe
    for (const ext of pluginDef.extensions) {
      for (const peer of allPlugins) {
        const peerEp = peer.extensionPoints.find(ep => ep.name === ext.extensionPointName);
        if (peerEp && peer.status === "Connected") {
          await snsSubscribe(peerEp.eventTopicArn, pluginDef.eventCollector);
        }
      }
    }
    // For each EP this plugin offers: find peer plugins' extensions and subscribe them
    for (const ep of pluginDef.extensionPoints) {
      for (const peer of allPlugins) {
        if (peer.id === pluginDef.id) continue;
        const matchingExt = peer.extensions.find(e => e.extensionPointName === ep.name);
        if (matchingExt && peer.status === "Connected") {
          await snsSubscribe(ep.eventTopicArn, peer.eventCollector);
        }
      }
    }
  } else if (action === "disconnect") {
    // Symmetric: list subscriptions on each affected topic, remove ones for this plugin's EventCollector
    for (const ep of pluginDef.extensionPoints) {
      const subs = await snsListSubscriptionsByTopic(ep.eventTopicArn);
      for (const peer of allPlugins) {
        if (peer.id === pluginDef.id) continue;
        const stale = subs.find(s => s.Endpoint === peer.eventCollector && peerHadExt(peer, ep.name));
        if (stale) await snsUnsubscribe(stale.SubscriptionArn);
      }
    }
    // Plus remove subscriptions from peer EPs to this plugin's EventCollector
    for (const ext of pluginDef.extensions) {
      for (const peer of allPlugins) {
        const peerEp = peer.extensionPoints.find(e => e.name === ext.extensionPointName);
        if (peerEp) {
          const subs = await snsListSubscriptionsByTopic(peerEp.eventTopicArn);
          const stale = subs.find(s => s.Endpoint === pluginDef.eventCollector);
          if (stale) await snsUnsubscribe(stale.SubscriptionArn);
        }
      }
    }
  }
}
```

**Idempotency**: `snsSubscribe` is idempotent at the AWS level (calling Subscribe twice with the same endpoint/topic returns the existing SubscriptionArn). `snsUnsubscribe` is best-effort (404 if already gone — swallow).

**Cold-start reconciliation**: when admin's EventColl cold-starts, run `manageSubscriptions(adminPluginDef, "connect")` once for every Connected plugin in Plugin RM. Catches subscriptions that may have been lost (e.g. SNS topic deleted+recreated, plugin restarted with new eventCollector ARN, etc.). Cheap because subscribe is idempotent.

### Checklist

```
Step 1
  [x] 1.1  scanPluginRm — reused existing scanByTableName helper (same status-filter
           shape as mkUpdateApiSchema).
  [x] 1.2  snsSubscribe/snsUnsubscribe wrappers — reused existing
           subscribeQueueToTopic / unsubscribeQueueFromTopic from
           @reventlessdev/rescript-aws-sdk/src/SNS_Helpers (already idempotent —
           lists existing subscriptions first, swallows 404 on unsubscribe).
  [x] 1.3  mkManageSubscriptions(tableName) in AdminEventCollectorEntryPoint.mjs —
           scans Plugin RM for Connected peers (excluding the connecting plugin),
           subscribes/unsubscribes in both directions per the plan pseudocode.
  [x] 1.4  Added manageSubscriptions field to PluginExtensionPoint_Plugin.Spec +
           PluginExtensionPoint_Builder.Spec + Plugin_ExtensionPoint_Builder.Config
           (deploy-time defaults to None). callHandler dispatches it alongside
           updateApiSchema on DoConnectPlugin / DoDisconnectPlugin.
  [x] 1.5  Cold-start reconciliation — reconcileSubscriptionsOnce fires as
           fire-and-forget inside buildHandler so the SQS handler is ready
           immediately; idempotent at the SNS level so safe to repeat.
  [ ]      Verify (Step 4): deploy two example plugins; admin logs
           "[manageSubscriptions] subscribed …" for each cross-plugin link.
```

---

## Step 2 — IAM permission updates

Files: wherever the admin Lambda role policy is generated (likely `reventless-aws/src/Platform.res` near the admin deploy block).

The admin's Lambda role needs new statements:

```json
{
  "Sid": "AllowAdminManageCrossPluginSnsSubscriptions",
  "Effect": "Allow",
  "Action": [
    "sns:Subscribe",
    "sns:Unsubscribe",
    "sns:ListSubscriptionsByTopic"
  ],
  "Resource": "arn:aws:sns:*:*:*EventTopic-*"
},
{
  "Sid": "AllowAdminDescribeSubscription",
  "Effect": "Allow",
  "Action": "sns:GetSubscriptionAttributes",
  "Resource": "*"
}
```

The `Resource` pattern matches Reventless's EventTopic naming convention. Tightening per-stack: scope to `arn:aws:sns:eu-west-1:<account>:CorePluginExtPointEventTopic-*` and the plugin-EP topic names that follow `<EpName>EventTopic-*`.

Each plugin EventCollector SQS queue's resource-based policy must already allow `SendMessage` from any SNS topic in the account (or from the admin's role). Today the policy is scoped to a single SNS topic ARN — too narrow for cross-plugin. Either:
- (a) Widen to allow all SNS topics in the account (using `aws:SourceAccount` condition for security)
- (b) Have admin's `manageSubscriptions` also update the SQS queue policy via `sqs:SetQueueAttributes` (heavier; gives admin sweeping SQS perms too)

Option (a) is simpler and safe with the SourceAccount condition. Recommended.

### Checklist

```
Step 2
  [x] 2.1  Cross-plugin SNS perms added to admin Lambda role in
           PluginRuntime_Builder.forPluginEventCollector — only the admin EC
           Lambda (detected via no registered eventCollectorContext) gets a
           dedicated RolePolicy granting sns:Subscribe / sns:Unsubscribe /
           sns:ListSubscriptionsByTopic / sns:GetSubscriptionAttributes. Plugin
           ECs keep the narrow IAM perimeter from connectLambda.
  [x] 2.2  EventCollectorChannel_Helpers.createQueuePolicy widened to a single
           statement allowing SendMessage from any in-account SNS topic whose
           name matches `*EventTopic-*` (arnLike +
           stringEquals(aws:SourceAccount=<accountId>)). Account ID extracted
           from the queue's own ARN (segment 4). Same policy applies to every
           plugin EC queue + the admin EC queue, so runtime-created cross-
           plugin subscriptions are accepted without a redeploy.
  [ ]      Verify (Step 4): aws iam simulate-principal-policy confirms admin
           role can Subscribe to a sample peer EP topic.
```

---

## Step 3 — Retire `PluginConnectExtension_Builder` subscribe path

Files:
- `reventless/reventless-core/src/admin/PluginConnectExtension_Builder.res` — `callHandler`'s `DoConnectPlugin` / `DoDisconnectPlugin` cases currently call `subscribe`/`unsubscribe`. With admin owning subscription management, these become no-ops.
- The whole extension might become unnecessary IF its only purpose was subscription management. Check: does it produce any other actions besides Connect (which is upstream of admin) and the subscribe/unsubscribe directives?

Looking at the current `mapIncomingEvent`:
- `UnknownPluginDetected` → emit ConnectPlugin (this is STILL needed — it's how plugins bootstrap)
- `PluginConnected/Reconnected for OTHER plugin` → Call(DoConnectPlugin) (now redundant if admin handles it)
- `PluginDeactivated for OTHER plugin` → Call(DoDisconnectPlugin) (now redundant)

So `PluginConnectExtension` keeps the `UnknownPluginDetected` → `ConnectPlugin` case (the self-Connect bootstrap from Phase 1) and drops the cross-plugin Call cases.

The plugin-side Connect bootstrap doesn't need peer plugin awareness anymore — it only needs to know its own ID. Spec simplifies to `{pluginDefinition}` only (drop `extensionPointsOutputs`, `extensionsOutputs`, `runtimeOps`, `resourceNaming`).

### Checklist

```
Step 3
  [x] 3.1  PluginConnectExtension_Mapping.Spec trimmed to a single field
           (`pluginDefinition`). PluginConnectExtension_Builder.Spec inherits
           via `module type Spec = PluginConnectExtension_Mapping.Spec`, so the
           deploy-time builder picks up the trim automatically.
  [x] 3.2  Subscribe / unsubscribe helpers deleted from the mapping. The
           ReventlessCore.PluginRuntimeOperations.operations record lost
           `topicSubscription`; AWS Util_TopicSubscription_Runtime.res removed
           outright; in-memory adapter's runtimeOps trimmed to messagePublish
           only.
  [x] 3.3  mapIncomingEvent now matches only `UnknownPluginDetected if pluginId
           == id` (self-bootstrap → emit ConnectPlugin). Cross-plugin
           PluginConnected / PluginReconnected / PluginDeactivated cases drop
           to no-ops since admin's manageSubscriptions owns that work now.
  [x] 3.4  Plugin_Helpers.createConnectPluginExtension simplified — drops
           extensionPointsOutputs / extensionsOutputs / runtimeOps /
           resourceNaming labels; Plugin_Builder.res call site updated to match.
           AdminEventCollectorEntryPoint.mjs reconstructs the Connect extension
           with only `pluginDefinition` and drops the dead `topicSubscription`
           stub from runtimeOps. PluginExtensionPointEntryPoint.mjs cleaned up
           the same way.
  [ ]      Verify (Step 4): a plugin's bundled Lambda has a smaller
           HANDLER_CONFIG (no extensionPointsOutputs / extensionsOutputs).
```

---

## Step 4 — Live verification with online-shop-hybrid

End-to-end fixture from Phase 2's Step 5, now with cross-plugin events actually flowing:

1. Both plugins deploy and Connect successfully (Phase 1).
2. Admin's `manageSubscriptions` creates the subscription: `OrderingOrders_ExtensionPointEventTopic-* → CatalogPluginEventColl-*`.
3. Place an order via AppSync.
4. Order aggregate emits Placed → admin EventColl re-publishes as `ItemOrdered` on `Ordering.Orders` EventTopic → SNS fans out to Catalog's EventCollector SQS.
5. Catalog's EventCollector lambda fires, runs `Orders_Extension.mapIncomingEvent`, emits `PublishStateChangeSliceCommand(RecordDemand(…))`.
6. `RecordProductDemand` slice processes the command → `ProductDemands` RM row appears.

### Checklist

```
Step 4
  [ ] 4.1  Confirm Step 1's verification: admin logs subscription creation on Connect
  [ ] 4.2  aws sns list-subscriptions-by-topic on Ordering.Orders EP shows CatalogPluginEventColl as a subscriber
  [ ] 4.3  Place an order; CatalogPluginEventColl receives the ItemOrdered SNS message (CloudWatch metric)
  [ ] 4.4  Orders_Extension handler dispatches; RecordProductDemand command published
  [ ] 4.5  ProductDemands RM table has a row for the productId
  [ ] 4.6  Deactivate Catalog plugin → admin's manageSubscriptions removes the subscription; aws sns list-subscriptions-by-topic confirms removal
  [ ]      Verify: full cross-plugin event flow + clean teardown on disconnect
```

---

## Honest concerns / unresolved

1. **Plugin RM scan latency.** On every Connect, admin scans the Plugin RM to know about peers. For O(100) plugins this is fine; for O(1000+) it's a problem. Mitigation: cache the scan in-Lambda with a short TTL (we already do this for the plugin-status gate — see `PLUGIN_RM_CACHE_TTL_MS`). Cache invalidation on Connect/Disconnect events keeps it fresh.

2. **Subscription drift.** AWS-side, subscriptions can be deleted out-of-band. Admin's cold-start reconciliation should self-heal, but a periodic reconciliation job (e.g. heartbeat-triggered) would be more robust. Out of scope for the initial cut.

3. **Subscription filter policies.** Today each subscription gets every event on the topic. For some EPs that's wasteful (plugins receive events for variants they don't care about). SNS filter policies could narrow this. Out of scope.

4. **Cross-region / cross-account.** This plan assumes all plugins live in the same AWS account and region. Cross-region/account adds complexity (cross-account topic policies, sns:Subscribe across boundaries). Out of scope.

5. **Migration from existing (broken) per-plugin subscribe path.** No live subscriptions exist today (the path is stubbed), so there's no state to migrate from. Clean slate.

6. **The order of operations during Connect matters.** Admin first appends `Connected` to Plugin aggregate → projects to Plugin RM → `manageSubscriptions` reads Plugin RM. If `manageSubscriptions` runs before the RM projection finishes, the connecting plugin won't be in the scan results. Two options: (a) run manageSubscriptions AFTER the EP's `DoConnectPlugin` callHandler is invoked (downstream of the projection) — natural with existing event flow; (b) include the connecting plugin's definition synchronously in the scan results (in-memory merge before AWS read). (a) requires the existing `updateApiSchema` hook ordering to also be event-driven (which it is — fires on outgoing events from admin EP, downstream of projection).

## What changes downstream

After Phase 3, both prior plans simplify:
- **Phase 1** — `PluginConnectExtension`'s Spec drops `extensionPointsOutputs` and `extensionsOutputs` (Step 3 above). HANDLER_CONFIG carries less.
- **Phase 2** — No simplification, but the cross-plugin event flow that Phase 2's Step 5 verifies finally works end-to-end without manual SNS poking.

## References

- [Util_TopicSubscription_Runtime.subscribe](../../reventless/reventless-aws/src/util/Util_TopicSubscription_Runtime.res) — already-implemented AWS SDK wrapper (just unused)
- [PluginConnectExtension_Builder.callHandler](../../reventless/reventless-core/src/admin/PluginConnectExtension_Builder.res#L52) — current per-plugin subscribe path (to be retired in Step 3)
- [PluginExtensionPoint_Plugin.callHandler](../../reventless/reventless-core/src/admin/PluginExtensionPoint_Plugin.res#L72) — admin's DoConnectPlugin dispatch (where `manageSubscriptions` hooks in alongside `updateApiSchema`)
- [Phase 1](./plugin-eventcollector-runtime-rewire.md), [Phase 2](./plugin-eventcollector-runtime-rewire-generic.md)
