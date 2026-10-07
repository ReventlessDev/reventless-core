# Plan: cross-plugin event routing has an unobserved teardown, untouched hardening, and dead DCB plumbing

**Date:** 2026-10-07<br/>
**Status:** Backlog — extracted from [../done/plugin-eventcollector-runtime-rewire-cross-plugin.md](../done/plugin-eventcollector-runtime-rewire-cross-plugin.md) and [../done/plugin-eventcollector-runtime-rewire-dcb-routing.md](../done/plugin-eventcollector-runtime-rewire-dcb-routing.md) when they closed. §1 needs a live deploy; §2 needs evidence (scale, drift, cost); §3 needs a decision and a real use case.<br/>
**Relates to:** [../done/aws-plugin-activate-deactivate-resolver.md](../done/aws-plugin-activate-deactivate-resolver.md) (the Deactivate mutation §1 drives)

---

In plain words: when plugin A consumes events plugin B publishes, the platform's admin
EventCollector subscribes A's queue to B's SNS topic at Connect time and removes the subscription
when a version disconnects, deactivates or retires (`manageSubscriptions` /
`reconcileSubscriptionsOnce` in `reventless/aws/src/adapter/Runtime/EventCollectorEntryPoint_Ops.res`;
the admin's SNS grant in `reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res`).
Subscribing has been observed on AWS in both directions. These are the pieces that have not.

## 1. Teardown on Deactivate has never been observed

`VersionDeactivated` and `VersionRetired` dispatch `DoDisconnectPlugin`, which unsubscribes. No
one has watched it happen on a deployed stack.

Done looks like: on alpha, Deactivate a plugin through the admin mutation; the admin
EventCollector logs the unsubscribe; `aws sns list-subscriptions-by-topic` on the peer's topic no
longer lists the deactivated plugin's queue. Then Activate it and confirm the subscription
returns. `VersionActivated` itself dispatches no `DoConnectPlugin` — re-subscribing relies on the
plugin's next Connect — so check how long that takes, and whether Activate should resubscribe
directly.

## 2. Hardening the original plan named and left out

None of these has a symptom today; each becomes worth doing when its trigger shows up.

| Item | Today | Trigger |
|---|---|---|
| Plugin read-model scan per Connect | uncached full scan (`scanByTableName`, limit 1000) | Connect latency grows with plugin count |
| Subscription drift | healed only on the admin Lambda's cold start | a subscription deleted out of band stays gone until the next cold start |
| SNS filter policies | every subscription receives every event on the topic | a consumer paying for traffic it discards |
| Cross-account / cross-region plugins | unsupported; queue policy is scoped to the account | a deployment that splits plugins across accounts |

For drift, a heartbeat-triggered reconcile reusing `reconcileSubscriptionsOnce` is the obvious
shape.

## 3. `dcbSources` is plumbing with no consumer

`Plugin.extensionDefinition.dcbSources` (in `reventless/spec/src/components/Plugin.res`) and both
DCB branches of `manageSubscriptions` exist, but
`Plugin_Helpers.extractExtensionDefinitions` always writes `dcbSources: []`, so the branches never
run. Filling it was blocked on the Extension model, which holds one extension point per mapping
and has no per-Source declarations.

There is also no use case: every `<X>DcbEventLog` Source in the examples reads its **own**
plugin's log, and the repo rule is that cross-plugin traffic goes through ExtensionPoint /
Extension only — a plugin reading another plugin's DCB log directly would bypass that boundary.

Decide one of:

- **Remove** `dcbSources`, `pluginDefinition.dcbEventLog`'s routing use, and the two DCB branches —
  less code that looks live and is not. `dcbSources` is persisted in Connect events, so removal
  must keep old payloads decoding (see the required-scalars guard in
  `reventless/core/tests/plugin/`).
- **Keep and finish**, only once a real cross-plugin DCB consumer exists that an extension point
  cannot serve: a multi-Source Extension model, populate `dcbSources` from it, and a live
  two-plugin check (subscription created, event delivered, teardown on Disconnect).
