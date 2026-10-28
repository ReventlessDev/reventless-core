# Read Side Fed Straight from an Extension Point

> **Status:** Analysis · nothing built. Written 2026-10-28, from the question whether an
> Extension could update another plugin's read models or StateView slices directly. Extended the
> same day with the replay analyses, use cases, a comparison with joining, and a recommendation;
> step 1 and 2 of the recommendation are planned in
> [another plugin's facts come in through the plugin's own log, once](../plans/another-plugins-facts-come-in-through-the-own-log-once.md).
>
> **Questions and short answers:**
>
> 1. *Can an Extension that hears another plugin's extension point update a ReadModel or a
>    StateView slice directly, and is there an example?* **Not today.** An Extension can only
>    send commands, and a view hears only its own plugin's events. The way in is Extension →
>    slice → the plugin's own event → view, which the hybrid catalog's demand count shows
>    ([§2.3](#23-what-stops-it), [§3](#3-what-the-current-route-gives)).
> 2. *Did such a feature exist?* **Yes, from February 2024, and its plumbing is still in the
>    code.** An unrelated safety check at plugin assembly has rejected it since April 2026, and
>    it never worked on the local platform ([§2](#2-what-existed)).
> 3. *Why shouldn't it be possible, and would it make sense?* **It fits CQRS and plugin
>    isolation, but breaks the promise that a view can be rebuilt from its own plugin's log**,
>    and it loses the decision that drops duplicates today ([§5](#5-is-it-a-good-idea)).
> 4. *What do the replay analyses say about it?* **Every one assumes a view can be refilled
>    from a stored log, and an extension point's events are stored nowhere**, so no replay that
>    exists or is planned reaches a directly fed view ([§4](#4-replay-what-the-other-analyses-say)).
> 5. *Where does it make sense, and where not?* **Only for display copies, status mirrors,
>    activity monitors, refillable indexes and personal data shown but not owned; never where the
>    plugin decides on, counts, mixes, must audit or must rebuild the fact.** Neither shop
>    example qualifies ([§6](#6-use-cases)).
> 6. *Wouldn't a GraphQL join do for a display copy?* **For screens a join is the better answer,
>    and the join in the client is already built.** A join across plugins inside GraphQL is
>    refused today and worth building only for a client other than the UI; a copy is needed only
>    where the server itself needs the value ([§6.4](#64-joining-instead-of-copying)).
> 7. *How could it be designed now?* **As a read-side subscription of its own**, declared on the
>    projection, visible in the plugin structure and paired with a refill, not by reopening the
>    dormant path ([§7](#7-design-options)).
> 8. *Drop it or support it?* **Drop it for now.** Delete the dormant plumbing, keep the write
>    route as the only one and make it drop repeats, and reopen the direct feed only when a server
>    must show another plugin's personal data, together with a refill
>    ([§8](#8-recommendation)).
> 9. *Can an extension point replay its history to a plugin that joins later?* **Not today.**
>    The workable shape is the provider re-running its own mapping over its log for that one
>    subscriber, DCB providers first; stable ids and dropping a handled command are its first
>    prerequisites, and planned ([§4.4](#44-ways-to-give-an-extension-point-a-replay),
>    [RSQ4](#11-open-questions)).

**Relates to:** [Extension component doc](../../packages/doc/docs-app/components/extension.md),
[mixed-source ReadModel plan](../plans/done/mixed-source-readmodel.md),
[reconnect replay analysis](reconnect-replay-missed-changes.md),
[time automations analysis](automations-that-run-on-a-time.md),
[protecting prod resources analysis](protecting-prod-infrastructure-resources.md),
[event format review](event-format-and-meta-review.md),
[the plan](../plans/another-plugins-facts-come-in-through-the-own-log-once.md)

**Id prefixes.** The use cases where a direct feed fits are numbered RSU1 to RSU5, those where
it doesn't RSN1 to RSN7; open questions are RSQ1 to RSQ8. **RS** stands for *read side*; **U**,
**N** and **Q** for *use*, *no* and *question*.

---

## 1 In plain words

Today, when plugin B wants to show something that plugin A announces through an extension
point, B has to take a detour through its own write side:

```
A's extension point ──event──▶ B's Extension ──command──▶ B's slice or aggregate
                                                        ──event──▶ B's own log ──▶ B's view
```

The question is whether B's view (a ReadModel or a StateView slice) could take A's published
event directly:

```
A's extension point ──event──▶ B's view
```

The answers, in short:

- **It existed.** A direct feed was added in February 2024 and its plumbing is still in the
  code. Since April 2026 a safety check at plugin assembly rejects it, so nobody can use it any
  more. It also never worked on the local platform. See [section 2](#2-what-existed).
- **It breaks a promise the framework relies on.** Every replay analysis treats a view as
  disposable, because it can be refilled from a stored log. Every replay mechanism that exists
  or is planned reads a stored log. An extension point's events are stored nowhere, so a
  directly fed view can't be refilled. See [section 4](#4-replay-what-the-other-analyses-say).
- **It is a good idea for a narrow kind of view**: a display copy of another plugin's facts
  that this plugin only shows and never decides on. It is a bad idea as the default way to bring
  another plugin's facts in. See [section 5](#5-is-it-a-good-idea) and
  [section 6](#6-use-cases).
- **Recommendation: drop it for now.** Delete the dormant plumbing, keep the write route as the
  only one, and make that route safe for counting views. Reopen it when a plugin must show
  another plugin's personal data from the server without copying it into its log. Then build a
  read-side subscription that needs no Extension, marked as not refillable, together with a
  way for the provider to send its state again. See [section 7](#7-design-options) and
  [section 8](#8-recommendation).

Terms used below:

- **Extension point (EP):** a plugin's published contract. It turns the plugin's internal events
  into public events, such as `Ordering.Orders` publishing `ItemOrdered`.
- **Extension:** the subscribing side of an EP in another plugin. Its `mapIncomingEvent` turns
  each public event into commands for its own plugin.
- **Event collector:** the queue plus handler that delivers events to a consumer. On AWS this is
  an SQS queue subscribed to SNS topics.
- **Replay:** reading stored events again, in order, to build state. A **rebuild** is a replay
  into an empty view.
- **Directly fed view:** a view that consumes another plugin's EP events without them first
  being stored in its own log.

## 2 What existed

### 2.1 The 2024 feature

Three commits from 29 February to 4 March 2024 added it:

| Commit | What it did |
|---|---|
| [03c400cf2](https://github.com/ReventlessDev/reventless-core/commit/03c400cf2dd7d8624a4fcbe8bf1e933e3cb62260) | `ReadModel.T` gained `enqueueEvent` (put an event straight into the read model's collector queue) and `sourceNames` |
| [e2913c809](https://github.com/ReventlessDev/reventless-core/commit/e2913c809f8a108155d57bd4968d4257ec5a1e23) | "support ExtensionPoints as source for Projections" |
| [0f8ee4ec7](https://github.com/ReventlessDev/reventless-core/commit/0f8ee4ec7553b890dcae9b90e78ffc83c88a1aff) | AWS `ForeignReadModel`: a read model whose collector is an SQS queue |

How it worked:

1. A projection named the EP as its source: `Mapping.Make(OrderingSpec.Orders_ExtensionPoint, …)`.
   The EP spec already has the shape a projection source needs (`name`, `Id`, `@schema type
   event`; see [Projection.res:5-10](../../reventless/spec/src/types/Projection.res#L5-L10)), so
   this compiled without changes.
2. At assembly the plugin inverted every read model's `sourceNames` into
   `readModelNamesForSourceName` (source name → read models), plus a table of each read model's
   `enqueueEvent`.
3. The topic filter at that time silently skipped a source name it had no topic for. So the
   read model subscribed only to its own aggregates and ignored the EP name.
4. The **Extension's incoming handler** did the delivery. After applying the commands from
   `mapIncomingEvent`, it looked up `event'.meta.service` (the EP name) in
   `readModelNamesForSourceName` and enqueued the raw event into each matching read model. The
   read model's normal dispatch, which matches `meta.service` against `Mapping.sourceName`,
   then ran the projection.

Two limits were built in from the start:

- **An Extension had to exist.** The forwarding lived inside the Extension's handler, so a
  plugin needed an Extension on that EP even when it had nothing to command.
- **Only ReadModels.** StateView slices did not exist yet.

### 2.2 What is left today

The plumbing survived every refactoring since:

- The forwarding still runs after the commands in
  [Extension_Operations.res:175-189](../../reventless/core/src/components/Extension/Extension_Operations.res#L175-L189),
  with the original `// FIXME Error handling`.
- The source → read-model index is still built in
  [Builder_Helpers.res:121-177](../../reventless/core/src/components/Builder_Helpers.res#L121-L177).
- On AWS, a May 2026 rewire carried it into the bundled collector handler: queue URLs as
  `PRM_<readModel>_QUEUE_URL`, and the index in HANDLER_CONFIG, scoped per extension
  ([EventCollectorEntryPoint_Ops.res:642-669](../../reventless/aws/src/adapter/Runtime/EventCollectorEntryPoint_Ops.res#L642-L669)).
  The rewire plan noted that no example used it
  ([plugin EventCollector rewire plan](../plans/done/plugin-eventcollector-runtime-rewire-generic.md)).
- `StateViewSlice_Builder` also exposes an `enqueueEvent`
  ([StateViewSlice_Builder.res:215](../../reventless/core/src/components/StateViewSlice/StateViewSlice_Builder.res#L215)),
  but nothing indexes StateView slices by source.
- [ForeignReadModel_Builder.res](../../reventless/aws/src/components/ForeignReadModel_Builder.res)
  still exists, with no references. The side-effect conversion plan already lists it as dead
  ([side-effect entry-point conversion plan](../plans/task-sideeffect-callbackfunction-conversion.md)).
- A related dormant hook: an extension's `dcbSources` (consume another plugin's DCB log
  directly) is wired into AWS subscription management but always `[]`
  ([Plugin_Helpers.res:362-370](../../reventless/core/src/plugin/component/Plugin_Helpers.res#L362-L370)).

### 2.3 What stops it

1. **The assembly check.** The [mixed-source ReadModel plan](../plans/done/mixed-source-readmodel.md#phase-2--source-name-typo-fail-fast)
   (commit [f0edfb8cb](https://github.com/ReventlessDev/reventless-core/commit/f0edfb8cbe8409d0665e2797e7321323dffd2e79),
   26 April 2026) made assembly fail when a `Mapping.sourceName` is not one of the plugin's own
   event topics ([ReadModel_Builder.res:97-110](../../reventless/core/src/components/ReadModel/ReadModel_Builder.res#L97-L110)).
   Its goal was to catch typos. An EP name is never one of the plugin's own topics, so the check
   rejects EP-sourced projections along with typos. The plan doesn't mention EP sources, so this
   looks like a side effect, not a decision.
2. **The local platform.** The local collector's `enqueueEvent` does nothing
   ([LocalEventCollectorChannel.res:27](../../reventless/local/src/adapter/EventCollector/LocalEventCollectorChannel.res#L27)),
   so the feature never worked locally.
3. **No subscription of its own.** On AWS, A's EP topic is subscribed to B's collector only
   when B has an Extension on that EP
   ([EventCollectorEntryPoint_Ops.res:428-442](../../reventless/aws/src/adapter/Runtime/EventCollectorEntryPoint_Ops.res#L428-L442)).

So the feature didn't get lost in a refactoring. Its pieces were carried along faithfully, and
one unrelated safety check then made it unreachable.

## 3 What the current route gives

The [Orders extension](../../examples/online-shop-hybrid/catalog/src/Extension/Orders_Extension.res)
in the hybrid catalog is the reference. It turns `ItemOrdered` into a `RecordDemand` command on
the [RecordProductDemand slice](../../examples/online-shop-hybrid/catalog/src/ProductDemand/StateChange/RecordProductDemand.res).
The slice's events feed the [ProductDemand view](../../examples/online-shop-hybrid/catalog/src/ProductDemand/StateViewStream/ProductDemand_Projection.res).

The detour costs two files, one command hop and one stored event per incoming fact. It buys
four things:

1. **Duplicates are dropped by a decision.** The
   [RecordProductDemand decision](../../examples/online-shop-hybrid/catalog/src/ProductDemand/StateChange/RecordProductDemand_Decision.res)
   returns `Ok([])` for an `orderId` it has already recorded. The view's `orderCount + 1` is
   safe only because of that. Projections themselves have no deduplication: a search of the
   read-model, StateView, collector and QueryDb code finds none.
2. **The fact is in the plugin's own log**, so every replay in
   [section 4.2](#42-what-replays-exist) reaches it.
3. **The plugin can refuse.** A decision can reject or ignore a fact that makes no sense in
   this plugin.
4. **One way in.** Every cross-plugin fact reaches the read side through the write side, so
   there is one rule to teach.

## 4 Replay: what the other analyses say

### 4.1 What the framework promises

Across the analyses and plans, one assumption recurs: a view is derived state, and losing it
costs nothing because it can be replayed from the log.

- The [protecting prod resources analysis](protecting-prod-infrastructure-resources.md#context)
  protects the event logs as "the system of record" and says losing a QueryDb projection "is
  recoverable (replay)". Its whole protection scheme follows from that split.
- The [plugin lifecycle redesign](plugin-lifecycle-redesign.md#8-rollout-steps) reshapes views
  and says "Rebuild projections by replay."
- The [event graph linking analysis](done/event-graph-linking.md#plugin-connectdisconnect-behavior)
  rebuilds its graph "on any full replay … no manual state reconstruction is needed."
- The [semantic geo-point plan](../plans/done/semantic-geo-point.md) changes a view's shape as "a
  projection rebuild, not an upcaster — a read model is derived state and replay is what it is
  for". The [retirement index plan](../plans/Backlog/retirement-folded-into-the-owner-index.md)
  needs a projection replay to fill a new index.
- The [time automations analysis](automations-that-run-on-a-time.md#56-schedules-set-by-events)
  rebuilds its schedules table from source events in order. Its answer to
  [T7](automations-that-run-on-a-time.md#9-open-questions) says a slice added later picks up
  schedules chosen before it existed. It also makes schedules deterministic "so a replay gives
  the same moment".
- The [directives doc](../../packages/doc/docs-app/concepts/directives.md#what-a-directive-is)
  draws the line on the same property: events are "logged, routed to topics, projected, and
  replayable"; directives are "not persisted, not replayed".

### 4.2 What replays exist

The promise is mostly principle. What is built:

| Replay | Reads | Status |
|---|---|---|
| Decision replay: an aggregate or slice rebuilds its state before deciding ([aggregate command handling review](aggregate-command-handling-review.md)) | the plugin's own log, per entity or tag | built, with snapshots |
| Local projection catch-up: after a restart, each projection gets the events between its checkpoint and the log's end ([ProjectionCheckpoint.res:1-45](../../reventless/local/src/adapter/ProjectionCheckpoint.res#L1-L45)) | the stored aggregate and DCB logs | built, SQLite backend only, covers a crash window |
| Schedules rebuild for time automations (`rebuildSchedules`, [AutomationSlice_Callback.res:310](../../reventless/core/src/components/AutomationSlice/AutomationSlice_Callback.res#L310)) | the slice's source events | built and tested, not yet started by a deploy |
| Rebuild of a deployed view | the plugin's own log | **not in this repo**: no script, bin or entry point here does it |
| Missed live updates in the browser ([reconnect replay analysis](reconnect-replay-missed-changes.md#why-the-current-architecture-doesnt-support-replay)) | change descriptors | not built; the analysis recommends a refetch, and replay scoped per subscriber |

Two findings of the reconnect replay analysis carry over:

- **Only the DCB log has a global position.** Aggregate logs are read per entity. The
  [event-history query plan](../plans/event-history-query-source-a.md#phase-3--local-resolver)
  records the same: "Aggregate logs are per-entity only." Any "replay from position N" works for
  DCB logs first.
- **Replay should be scoped by what the subscriber asked for**, not offered as full history to
  everyone.

### 4.3 What this means for a directly fed view

An EP's events are produced on the fly: the provider's `mapOutgoingEvent` turns its stored
events into public ones and publishes them, and nothing keeps the result. As far as replay is
concerned, a public EP event behaves like a directive. So:

1. **No replay in [section 4.2](#42-what-replays-exist) reaches a directly fed view.** All of
   them read a stored log, and the foreign facts are in none of the consumer's logs.
2. **Locally it is worse than the write route.** After a crash, the SQLite catch-up repairs a
   view fed through a slice from the slice's stored events. A directly fed view keeps the gap
   for good.
3. **The view's table becomes a system of record.** The protecting prod analysis's split no
   longer holds for it. Its table would need the protection the event logs get, and wipe tools
   would have to know it can't be refilled.
4. **Shape changes need the provider.** A semantic-geo-point-style reshape or a new index that
   needs a backfill can't be done from the consumer's side.
5. **Late joiners are equal.** A plugin connecting after the provider has history misses that
   history on either route. Only an EP replay would fix that, for both routes.

### 4.4 Ways to give an extension point a replay

Each would make directly fed views refillable. The first would also let late-joining Extensions
catch up.

1. **The provider re-runs its mapping for one subscriber.** It replays its own log from a
   position through `mapOutgoingEvent` and publishes only to the subscriber that asked. This
   follows the reconnect analysis's rule of replay scoped per subscriber. It needs a global
   position, so DCB providers come first. It also needs the mapping to give the same output
   later, as the time automations analysis demanded of schedules: a mapping that runs an async
   query or a directive must skip or repeat them consistently, and directives are never
   replayed.

   Two pieces sit close by. **When to start:** the moment a subscription is newly created.
   Subscription management already checks for an existing subscription before it creates
   one, but `subscribeQueueToTopic` returns nothing and its caller discards the result
   ([SNS_Helpers.res:17-35](../../rescript/aws-sdk/src/SNS_Helpers.res#L17-L35),
   [EventCollectorEntryPoint_Ops.res:349-361](../../reventless/aws/src/adapter/Runtime/EventCollectorEntryPoint_Ops.res#L349-L361)).
   Returning "created" or "existing" is the first step. **What is safe to replay into:** a
   consumer whose receiving slice drops a repeat by the source event's id
   ([section 8](#8-recommendation), step 2). A hand-written Extension that commands a
   slice other writers also use is not safe by default, since its commands would run twice.
   The source is always the provider's event log: a standard SNS topic keeps nothing to
   replay from.
2. **The transport keeps an archive.** EP topics are standard SNS topics
   ([ExtensionPoint_Builder.res:20](../../reventless/aws/src/components/ExtensionPoint_Builder.res#L20)).
   SNS archive and replay exist only for FIFO topics. The
   [event format review](event-format-and-meta-review.md#45-opportunities-unlocked) notes that
   EventBridge brings replay "for free". Either way, the archive is limited by retention,
   AWS-only (the local platform has no equivalent), and replays to all subscribers unless
   filtered.
3. **The provider republishes current state.** On connect or on a schedule, the provider
   publishes one "this is how it is" event per entity. This only suits reference data. It is
   the opposite of the shop's own stance: the ordering view of available products notes that
   "Catalog is never asked to re-send what Ordering already has"
   ([AvailableProducts_Projection.res](../../examples/online-shop-hybrid/ordering/src/CatalogProduct/StateViewStream/AvailableProducts_Projection.res)).

## 5 Is it a good idea

### 5.1 Does it fit the overall design

In part:

- **Plugin isolation holds.** The view consumes the EP's public event type from the provider's
  spec package, the same contract an Extension consumes. It does not reach into the provider's
  source or log.
- **CQRS holds.** A view is a function of events. It doesn't matter to CQRS whose log the events
  come from, and one view can already project from aggregates and the DCB log together
  ([mixed-source ReadModel plan](../plans/done/mixed-source-readmodel.md)).
- **It was the original intent.** The 2024 commits show the framework was meant to allow this.
- **Event sourcing pulls against it.** [Section 4](#4-replay-what-the-other-analyses-say) shows
  how much of the framework, and how many plans, assume a view can be thrown away and rebuilt.
  A directly fed view is the first view for which that isn't true.

So it fits CQRS and plugin isolation, and it conflicts with the replay promise. Without an EP
replay ([section 4.4](#44-ways-to-give-an-extension-point-a-replay)) it fits only where losing
the view's history is acceptable. With one, most of the conflict goes away.

### 5.2 Objections

Strongest first.

1. **The view cannot be refilled.** See [section 4.3](#43-what-this-means-for-a-directly-fed-view).
   This makes the view's table a system of record, against the framework's split between logs
   and views.
2. **Duplicates are not dropped.** Delivery is at-least-once and no projection deduplicates. An
   accumulating view (a counter, a sum, an appended list) silently drifts on redelivery.
   Overwrite-style projections (`Set`, `Delete`, `UpdateWithDefault` that copies fields) are
   safe.
3. **No order.** EP topics are standard SNS, which doesn't keep order. Two updates of one entity
   can arrive swapped, and a view that combines its own events with foreign ones has no common
   order across them. A foreign `Update` can arrive before the row exists and be dropped. With
   the write route a decision can at least see this; with a direct feed it is lost without a
   trace.
4. **Nothing to decide on later.** Slices read events, not views. If the plugin later needs to
   decide on the fact, it must add the write route and move the view over, and the view's
   history is gone by then (objection 1).
5. **Two ways to do the same thing.** Developers need a rule for when to use which
   ([section 6](#6-use-cases)). Without one, the direct feed gets chosen because it is shorter,
   including for counters where it drifts.
6. **History doesn't explain the view.** The plugin's event history, the domain graph and the
   GWT corpus no longer account for every row.

None of these is a reason to refuse the feature. Together they mean it must be **narrow, opt-in
and visible**.

## 6 Use cases

### 6.1 Where it makes sense

| # | Use case | Why it fits |
|---|---|---|
| RSU1 | **Display copy of another plugin's reference data**: product name and price beside an order line, a customer's display name in a support list | Overwrite-only; nothing in the consumer decides on it; a stale value is corrected by the next change |
| RSU2 | **Last known status of a foreign entity**: a shipment's status in the order view, an account's state in a helpdesk | Latest wins. Needs a version or timestamp in the event so a swapped pair doesn't win the wrong way (objection 3) |
| RSU3 | **Operational monitor of recent activity**: a live feed of another plugin's events with a TTL on rows | History beyond the TTL is not wanted anyway, so not being able to refill costs nothing |
| RSU4 | **Lookup or search index over another plugin's entities**, when the provider republishes current state or has a replay | The index can be refilled from the provider ([section 4.4](#44-ways-to-give-an-extension-point-a-replay)) |
| RSU5 | **Personal data shown but not owned**: a contact's name or e-mail displayed beside the consumer's own records | No copy goes into the consumer's append-only log, so erasing it is a row delete. Compare the [personal field plan](../plans/a-personal-field-is-marked-redacted-and-encrypted-at-the-seam.md) |

**Screens don't need a copy.** For [RSU1](#61-where-it-makes-sense) and
[RSU5](#61-where-it-makes-sense), a screen can resolve another plugin's ids through that plugin's
`{list}Refs(ids)` reference door, which answers every view with a label. The UI joins the two,
and nothing is copied anywhere. These cases become real only when the **server** needs the
foreign value: a notification text naming a person, an e-mail, sorting or finding rows by it.
[Section 6.4](#64-joining-instead-of-copying) compares the joins with the copies.

### 6.2 Where it does not

| # | Use case | Why it doesn't fit |
|---|---|---|
| RSN1 | **The consumer decides on the fact**, now or likely later: placing an order checks the product is available | Slices read events, not views. The fact must be in the consumer's log |
| RSN2 | **The fact starts something**: an automation, a notification, a schedule | Automations consume the plugin's own events; a view can't start anything |
| RSN3 | **The view accumulates**: counts, sums, totals, appended lists, "first seen" | Redelivery double-counts; only a decision drops duplicates today |
| RSN4 | **Rows mix own and foreign events**: a row created by the consumer's event and changed by the foreign one, or the other way round | No common order; a change can arrive before the row and be lost |
| RSN5 | **The value must be exact or auditable**: money, billing, legal, anything a person is charged or paid by | A lost or swapped update is invisible and unrecoverable |
| RSN6 | **The consumer must check or translate the fact**: refuse nonsense, map ids, drop duplicates by a business key | Only a decision can refuse |
| RSN7 | **The view must survive rebuilds with full history** and the provider has no replay | It starts empty after any reshape (objection 1) |

### 6.3 The shop's examples, checked

- [ProductDemand](../../examples/online-shop-hybrid/catalog/src/ProductDemand/StateViewStream/ProductDemand_Projection.res)
  in catalog counts orders per product ([RSN3](#62-where-it-does-not)) and mixes catalog's
  `ProductAdded` with ordering's facts ([RSN4](#62-where-it-does-not)). **Keep the slice.**
- [AvailableProducts](../../examples/online-shop-hybrid/ordering/src/CatalogProduct/StateViewStream/AvailableProducts_Projection.res)
  in ordering only overwrites and deletes, so on its own it would be a
  [RSU1](#61-where-it-makes-sense) case. But
  [PlaceOrder](../../examples/online-shop-hybrid/ordering/src/Order/StateChange/PlaceOrder_Decision.res)
  decides on the same products ([RSN1](#62-where-it-does-not)), so the
  [SyncCatalogProduct slice](../../examples/online-shop-hybrid/ordering/src/CatalogProduct/StateChange/SyncCatalogProduct.res)
  must exist anyway. Once it does, the view reads its events for free. **Keep the slice.**

Neither current example is a candidate, which says something about how narrow the case is. A
fitting example would be a view that shows catalog product names in a part of the shop that never
decides on products, such as a support or reporting plugin.

### 6.4 Joining instead of copying

A display copy is one of four ways to show plugin A's data in plugin B. The other three either
join at read time or copy through the write side.

**1. Join in the client (built).** Every view has a `{list}Refs(ids)` reference door
([GraphQL_FragmentGenerator.res:613-650](../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res#L613-L650))
that returns id, label, image and retirement state, and nothing else. The UI kit collects the
referenced ids on a screen and asks each referenced view once per screen.

- **For:** nothing is copied, nothing has to be rebuilt, and the value is always current. A's
  owner and retirement rules apply, because A answers. Personal data stays only at its source.
- **Against:** only the client that does the join gets the value; an MCP tool or an external
  client has to repeat it. Only the narrow door's fields are available. B can't filter, sort or
  page by A's value. B's screen depends on A being up.

**2. Join in GraphQL (not built).** A field such as `product: Catalog_ProductRef` on B's type,
answered from A. Today this is refused at build time
([Api_Naming.res:158-174](../../reventless/core/src/components/Api/Api_Naming.res#L158-L174)):
under merged composition each plugin's document must be valid on its own, and on AWS the target
table's grant would sit on the declaring plugin's API role, which breaks plugin isolation. Two
ways could build it without breaking isolation, both on the
[merged API's rules](merged-api-push-free-approach.md#4-aws-feasibility--appsync-merged-apis):

- **A contributes the field to B's type with its own resolver** (the merged API's field-resolver
  pattern). A's role reads A's table, but A's document must declare a stub of B's type and its
  key field. The provider then knows the consumer, which reverses the dependency, and a stub that
  drifts fails the merge.
- **B's resolver calls A's reference door** through the merged endpoint. The dependency keeps its
  direction, at the cost of a hop, a system caller and batching to avoid one call per row.

Either way the field should return only A's `Ref` type. The merged API authorizes nested fields
per source API, not per field, so a richer type would bypass A's field-level rules. The local
platform could delegate easily, but local mirrors AWS, so there is no local-only shortcut.

- **For:** one query serves every client: generated UIs, MCP tools, external apps. Always
  current, nothing copied.
- **Against:** the most new work, in merge rules and auth. B depends on A at query time. No
  filtering or sorting by A's value. B's live updates don't fire when A's value changes. A
  resolver call per row unless batched.

**3. Copy through the write side (built).** The noted route of [section 3](#3-what-the-current-route-gives).

- **For:** B works when A is down. B can filter, sort, search and page by the value, its live
  updates carry it, decisions and automations can use it, and it can be rebuilt.
- **Against:** the copy lags A, costs storage and a hop, and personal data lands in B's log,
  where it needs encryption.

**4. Copy fed directly (dropped for now).** The copy's server-side benefits, with nothing in B's
log. But it can't be refilled ([section 4.3](#43-what-this-means-for-a-directly-fed-view)) and
nothing can decide on it.

**When to use which:**

| Need | Way |
|---|---|
| A screen shows A's name or picture | join in the client, the default |
| A client other than the UI needs A's label in the same call (an MCP tool, an external API) | join in GraphQL; the only case worth building it for, returning only the `Ref` type ([RSQ8](#11-open-questions)) |
| The server needs the value: a notification or e-mail text, filtering, sorting, searching or paging by it, an automation reading it | copy; noted by default, fed directly only in the case that would reopen it ([section 8](#8-recommendation)) |
| B decides on the value | noted copy only |

This narrows the direct feed further. The joins cover [RSU1](#61-where-it-makes-sense) and
[RSU5](#61-where-it-makes-sense) on screens with no copy at all, so a direct feed is left only for
what the server itself needs.

## 7 Design options

### 7.1 Option A: reopen the dormant path

Let the assembly check accept a source name that is an EP the plugin has an Extension on. Make
local `enqueueEvent` deliver. Keep everything else.

- **For:** smallest change, maybe a day of work. Most code exists and is wired on AWS.
- **Against:** the read side depends on an Extension existing, so a pure display view needs an
  Extension with an empty `mapIncomingEvent`. Delivery hides inside the Extension handler, after
  the commands, with the old `FIXME`: one failed enqueue fails the whole batch, commands
  included, and the retry re-sends the commands. Nothing says the view can't be refilled.
  StateView slices aren't covered.

### 7.2 Option B: a read-side subscription of its own

Make a foreign source a property of the view, not of an Extension.

1. **Declaration.** It stays what it was in 2024. A ReadModel's `_Projections.res` lists
   `Mapping.Make(OrderingSpec.Orders_ExtensionPoint, …)`, and the EP spec is the source. Nothing
   new to learn, and Projection GWT tests take the EP spec as their source unchanged.
2. **Assembly.** The check distinguishes three cases: an own topic, an EP spec (known because
   the source module comes from a `*Spec` package with an EP `name`), or a typo. Only the typo
   fails. The typo protection stays.
3. **Plugin structure.** `readSideDef` lists the foreign sources for each view and carries a
   `refillable: false` flag for such a view. Both must be optional fields: a required field
   added to the plugin structure wedges registration for plugins built before it. The domain
   graph draws the cross-plugin edge from them, and design tools can read them.
4. **Subscription.** AWS subscription management subscribes a peer EP topic to this plugin's
   collector when an Extension **or** a view lists it (a second loop next to
   [EventCollectorEntryPoint_Ops.res:428-442](../../reventless/aws/src/adapter/Runtime/EventCollectorEntryPoint_Ops.res#L428-L442)).
   At connect, a foreign source that no connected peer exposes is logged, not refused, like an
   Extension whose EP is missing.
5. **Dispatch.** The plugin collector's dispatcher, which already routes by `meta.service` to
   Extensions, routes to views as well. It uses `enqueueEvent` and the existing index, but
   outside the Extension handler, with its own error handling. The block in
   `Extension_Operations` goes.
6. **Local platform.** The in-process bus delivers the EP's events to the view as it already
   does to Extensions. The startup catch-up must leave such views out of its claim to have
   repaired everything.
7. **Guardrails** for [section 5.2](#52-objections):
   - A start-up log line names every directly fed view and says it can't be refilled from the
     plugin's log.
   - Its table gets the event logs' protection on prod (see
     [section 4.3](#43-what-this-means-for-a-directly-fed-view)).
   - The docs carry the tables of [section 6](#6-use-cases).
   - Deduplication is open as [RSQ3](#11-open-questions).

- **For:** no fake Extension, delivery isolated from commands, visible in the plugin structure,
  works on both platforms, one declaration syntax.
- **Against:** about a week across core, AWS and local, plus tests. It touches subscription
  management, which has a history of subtle connect/disconnect bugs.

### 7.3 Option C: keep the write side, generate the slice

Keep the detour, but stop writing it by hand. A "record" slice, generated from an EP, stores
each foreign event one-to-one as an own event and drops duplicates by the source event's id.
The view projects the plugin's own copy.

- **For:** keeps everything in [section 3](#3-what-the-current-route-gives), so every replay in
  [section 4.2](#42-what-replays-exist) keeps working. Duplicates are handled once, in the
  framework. The plugin can decide on the facts later without a migration. Design tools that
  generate cross-plugin contracts can write exactly this.
- **Against:** stores a copy of every foreign fact and keeps the extra hop. It saves code, not
  infrastructure. Personal data lands in an append-only log ([RSU5](#61-where-it-makes-sense)).

## 8 Recommendation

**Drop it for now.** No example needs it, it breaks the replay promise that much of the
framework relies on, and the write route is already cheap where design tools generate it.

1. **Delete the dormant plumbing** ([RSQ1](#11-open-questions)): the forwarding in
   `Extension_Operations`, the index in `Builder_Helpers`, the `PRM_*` queue URLs and their
   HANDLER_CONFIG entry on AWS, `ForeignReadModel_Builder`, and the empty `dcbSources`. Then say
   in the Extension doc that a view gets another plugin's facts through the write side. The
   present state, wired on AWS, unreachable by an assembly check and inert locally, is the worst
   option: it costs upkeep on every refactoring and promises something that doesn't work. It
   also isn't what a revival would need, since it requires an Extension and says nothing about
   refilling. Planned with step 2 in
   [another plugin's facts come in through the plugin's own log, once](../plans/another-plugins-facts-come-in-through-the-own-log-once.md).
2. **Keep the write route as the only route**, and make it safe for counting views. A generated
   record slice ([Option C](#73-option-c-keep-the-write-side-generate-the-slice)) should drop an
   event it has already recorded, keyed by the source event's id ([RSQ3](#11-open-questions)).
   Then a counter like the shop's demand is correct without a hand-written check, and the
   pair becomes safe to replay into once an EP replay exists (step 3).
3. **Write the EP replay as its own analysis when a reason comes up** ([RSQ4](#11-open-questions)).
   The provider-side re-run for DCB providers
   ([section 4.4](#44-ways-to-give-an-extension-point-a-replay), first way) helps late-joining
   Extensions on the write route as well, so it is worth having whether or not directly fed
   views ever come back.
4. **Reopen when one of these appears:**
   - a plugin must show another plugin's **personal data from the server** (a notification or
     an e-mail naming a person, finding rows by a name) and should not copy it into its
     append-only log ([RSU5](#61-where-it-makes-sense)). Screens alone don't count: they resolve
     names through the reference door ([section 6.1](#61-where-it-makes-sense));
   - copying another plugin's facts becomes a measured storage or latency cost.

   Then build [Option B](#72-option-b-a-read-side-subscription-of-its-own) together with a way
   to refill the view: the provider republishing its current state
   ([section 4.4](#44-ways-to-give-an-extension-point-a-replay), third way) or the EP replay.
   Never [Option A](#71-option-a-reopen-the-dormant-path): it ties views to an Extension and
   hides delivery inside the Extension's command handling.
5. **Shape contracts so both routes stay open.** An EP that publishes display data about an
   entity (a name, a picture) should carry one full-state event per change, latest wins and
   versioned, beside the events consumers decide on. A consumer can note it today and hear it
   directly later, and a republish has something to send. It costs nothing while the contract
   is on paper.
6. **Leave both shop examples as they are** ([section 6.3](#63-the-shops-examples-checked)).

## 9 StateView slices

A StateView slice projects `consumedEvent`, a subset of the DCB log's events matched by
constructor name ([StateViewSlice.res:128](../../reventless/spec/src/components/StateViewSlice.res#L128)).
A foreign event has its own type, and its constructor names may collide with the log's. So
StateView slices need a declaration that ReadModels don't. Two shapes:

- **A second consumed type:** `module ForeignSource = OrderingSpec.Orders_ExtensionPoint` plus
  `@schema type foreignEvent = | ItemOrdered({productId: …})`, with a second function
  `projectForeign`. The PPX checks that `foreignEvent` is a subset of the EP's `event`.
  Explicit, but two project functions.
- **One wrapped type:** `project` receives `Own(consumedEvent) | Foreign(foreignEvent)`. One
  function, but every existing StateView projection would change shape unless the wrapper is
  added only when a foreign source is declared.

The runtime half exists (`enqueueEvent` on the StateView builder). Indexing by source and the
dispatch from [section 7.2](#72-option-b-a-read-side-subscription-of-its-own) would extend to
StateView slices as they are. I'd do ReadModels first and add StateView slices once one real
view needs it ([RSQ5](#11-open-questions)).

## 10 Tools

Design tools that write cross-plugin contracts decide, per view, which route to write. They
need the plugin-structure fields of [section 7.2](#72-option-b-a-read-side-subscription-of-its-own)
step 3 to see a directly fed view, and the tables of [section 6](#6-use-cases) to choose. How a
tool asks is out of scope here.

## 11 Open questions

**RSQ1. Revive the dormant plumbing as Option B, or delete it?**
**Recommendation: delete it** ([section 8](#8-recommendation), step 1). Nothing uses it, it is
unreachable, and it isn't the shape a revival would need: it requires an Extension and says
nothing about refilling. Revisit if a plugin must show another plugin's personal data from the
server; then build Option B fresh, not this.

**RSQ2. If directly fed views come back, should they share the plugin collector, or should each
view's queue subscribe to the provider's topic itself?**
**Recommendation: share the plugin collector.** It already dispatches by `meta.service`, needs
one subscription per extension point, and keeps view queues out of connect management, which has
a history of subtle bugs. The price is one enqueue hop. Revisit if that hop shows up in a
measured latency budget, or the collector Lambda becomes a hotspot.

**RSQ3. How are repeated deliveries dropped?**
**Recommendation: on the write route, in the handler, by the command's stable id**, as the plan
does ([RF4 and RF5](../plans/another-plugins-facts-come-in-through-the-own-log-once.md#steps)),
not by a field each decision folds: the framework does it once, and a hand-written note can't
forget it. For directly fed views, if they return: overwrite-only projections, enforced by
refusing an accumulating action (`Update`, `Create`) at run time for such a view. Revisit if a
directly fed view genuinely has to count, which would need a framework deduplication table with
a write per event and a TTL policy.

**RSQ4. Which way should an extension point replay: the provider re-running its mapping per
subscriber, an archive in the transport, or the provider republishing its state?**
**Recommendation: the provider re-running its own mapping over its log for the one subscriber
that joined, DCB providers first** ([section 4.4](#44-ways-to-give-an-extension-point-a-replay)).
It works on both platforms, serves late-joining Extensions on the write route as well, and
needs no new infrastructure. An archive is AWS-only and FIFO-only and reaches every subscriber;
a republish suits only reference data. Revisit if a late joiner needs an aggregate provider's
history before a cross-instance read exists; a republish of current state can serve that one.

**RSQ5. How does a StateView slice declare a foreign event: a second consumed type, or one
wrapped type?** ([section 9](#9-stateview-slices))
**Recommendation: a second consumed type** (`foreignEvent` with `projectForeign`). Existing
projections keep their shape, the PPX can check the subset against the extension point's
`event`, and a view without a foreign source changes nothing. Revisit if most views that take
one also need to interleave both kinds in one function.

**RSQ6. When no connected peer exposes a view's foreign source, should connect log or refuse?**
**Recommendation: log a warning and show it in the plugin's status; don't refuse.** The peer
may simply deploy later, and Extensions are treated the same way today. Revisit if a view that
stayed empty unnoticed causes an incident.

**RSQ7. Should a directly fed view's table get the event logs' deletion protection on prod?**
**Recommendation: automatically.** Such a table can't be refilled, so it is a system of record,
and a plugin author can't be relied on to remember. Revisit once an extension-point replay
exists: a refillable view goes back to being disposable.

**RSQ8. When a client other than the UI first needs another plugin's labels in one call, how is
the GraphQL join built: the provider contributing the field, or the consumer calling the
reference door?** ([section 6.4](#64-joining-instead-of-copying))
**Recommendation: the consumer calls the provider's reference door**, batched, returning only
the `Ref` type. The dependency keeps its direction, the provider's schema needs no stub of the
consumer's type, and a drifting stub can't fail the merge. Revisit if the extra hop matters in
measured latency, or batching proves impractical in the resolver; then the provider-contributed
field.
