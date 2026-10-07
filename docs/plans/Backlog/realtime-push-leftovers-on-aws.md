# Plan: on AWS, the lifecycle pushes have no sender, the raw event stream is unwatched, and bursts are not coalesced

**Date:** 2026-10-07<br/>
**Status:** Backlog — extracted from [../done/aws-plugin-activate-deactivate-resolver.md](../done/aws-plugin-activate-deactivate-resolver.md), [../done/graphql-subscriptions-appsync.md](../done/graphql-subscriptions-appsync.md) and [../done/realtime-change-descriptors.md](../done/realtime-change-descriptors.md) when they closed. §1 waits on a decision shared with the client; §2 needs a deployed plugin with an SNS-backed event topic; §3 waits for subscriber load that does not exist yet.<br/>
**Relates to:** [../event-history-query-source-a.md](../event-history-query-source-a.md) (the read counterpart of the raw event stream in §2)

---

In plain words: "realtime push" is the server telling a connected browser that something changed,
instead of the browser asking again. Three kinds exist. Read-model change descriptors (Source B)
work on AWS and were observed arriving on 2026-08-22. What is left is below.

## 1. Plugin activate/deactivate never reaches a browser on AWS

The admin SDL declares `onPluginStatusChange` and `onUIFragmentChange`, each an `@aws_subscribe`
on a mutation (`Platform_PluginStatusChanged`, `Platform_UIFragmentRegistered` / `_Updated` /
`_Deregistered`, in `reventless/core/src/admin/Platform_AdminApi.res`). Locally the platform
publishes to both. **On AWS nothing calls those mutations**, so the subscriptions are declared
and silent.

- The natural sender is whatever projects the Plugin aggregate's `VersionActivated` /
  `VersionDeactivated` (and fragment register/deregister) events into the Plugin read model: it
  would need `appsync:GraphQL` on the platform API and one signed mutation call per transition.
- Core's other half — the socket host — is done: `Platform.res` now writes
  `platformApiSubscriptionEndpoint` into `config.json` (`Util_ShellConfig.subscriptionEndpoint`,
  commit `426d9322d`).
- The client half lives in `reventless-ui`: its `graphql-ws` client sends the
  `graphql-transport-ws` subprotocol, which AppSync refuses.

**Decide first, with the client:** either the client learns AppSync's own `graphql-ws`
protocol and the sender calls the two mutations above, or both subscriptions move onto the
AppSync Events transport the change descriptors already use — in which case the sender publishes
to an Events channel and the two `@aws_subscribe` declarations can go. Building the sender before
that choice risks building the wrong one.

Done looks like: on a deployed stack, Deactivate on a plugin removes its sidebar entry in an open
browser within a couple of seconds without a reload, and Activate restores it — the manual check
the original plan never got to run, locally or on AWS.

## 2. The raw event stream (Source A) has never been observed end to end

`EventLogSubscription_AppSync` (SNS → SQS → Lambda → Events channel) is built and wired for every
event topic that publishes through `EventTopicPublisher_SNS`. The hybrid example has none — its
topics use `EventTopicPublisher_DynamoDbStream` — so no domain event has ever been seen arriving
on this path.

- Done looks like: a deployed plugin with an SNS-backed event topic, a command fired, and the
  event observed on `on<Name>EventLog_eventAppended`'s channel.
- Open question carried over: should the `on<Name>EventLog_eventAppended` field be generated for
  every plugin with an event log (today) or only when a plugin opts in? It is an
  admin/observability feed; generating it everywhere widens every plugin's schema for a feature
  most never use. Settle it alongside [../event-history-query-source-a.md](../event-history-query-source-a.md),
  which adds the history query beside it.

## 3. Bursts are not coalesced

A bulk operation that touches 500 rows sends 500 change descriptors to every subscriber. The
designed fix is an `OnPublish` handler on the Events namespace that buffers a partition's burst
and sends one `BulkInvalidated` instead. AppSync Events' built-in JS runtime keeps no state
between published events, so this needs a Lambda data source (`handlerConfigs.onPublish`), the
coalescer's state machine, and unit tests. Since partitioned channels were never shipped, it
would coalesce per read model, not per partition.

Waits for evidence: a client that visibly struggles under burst traffic. The descriptor
`position` field the same plan deferred is **not** owed here — `live-update-state-payload`
shipped `seq` as the ordering token instead.
