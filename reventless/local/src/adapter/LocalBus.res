// Shared in-memory event and command bus.
// Each Platform.Make() creates a fresh isolated bus — no global state, no test interference.
//
// Event delivery uses Effect PubSub + Stream for fan-out and a countdown Deferred for
// completion signaling (Phase F of effect-stream-integration plan).
//
//  subscribeToEvents — creates (or reuses) a PubSub hub per topic (unbounded or bounded based
//    on capacity) and starts a drain fiber (via Effect.runFork). The fiber runs
//    Effect.scoped(PubSub.subscribe(hub)→…) synchronously up to the first Queue.take
//    suspension, registering the subscription before runFork returns. The subscriber count
//    for the topic is incremented synchronously.
//
//  publishEvent — uses the manually-tracked subscriber count (not PubSub.size, which measures
//    queued messages not subscriber count), creates a countdown done_ Effect and an allDone
//    Deferred. The publish path depends on capacity:
//      Unbounded (capacity=None): Effect.runSync(PubSub.publish) + separate Deferred.await_.
//        Synchronous fan-out; resolves in 2 microtask ticks.
//      Bounded (capacity=Some(n)): PubSub.publish + Deferred.await_ in one runPromise.
//        May suspend when any subscriber queue is full; resolves in 3 microtask ticks.
//
//  reset — shuts down all hubs (which terminates Stream.fromQueue consumers via PubSub.shutdown),
//    then clears all registries.
//
// Timing analysis:
//   Unbounded — Make():
//     tick 0: PubSub.publish (Effect.runSync) + Deferred.await_ runPromise starts
//     tick 1: Effect scheduler: drain fibers wake, call handlers, run done_; last resolves allDone
//     tick 2: Deferred.await_ promise resolves; publishEvent returns
//   → 2 microtask ticks (same as the previous Queue-based implementation)
//
//   Bounded — MakeBounded({let capacity = n}):
//     tick 0: Effect.runPromise(PubSub.publish → Deferred.await_) starts
//     tick 1: publish completes; drain fibers run; Deferred.succeed called
//     tick 2: Deferred.await_ promise resolves; publishEvent returns
//   → 3 microtask ticks (1 extra vs unbounded due to async publish)
//
// NOTE: PubSub.size in Effect measures buffered message count (not subscriber count).
// Subscriber count is tracked via a separate subscriberCounts dict.

// Message fanned out by PubSub to every subscriber's Queue.
// done_ is run by each subscriber after the callback returns; when the last subscriber
// finishes, done_ resolves allDone and publishEvent can return.
type queuedEvent = {
  service: string,
  meta: ReventlessCore.Message.meta,
  json: JSON.t,
  done_: Effect.t<unit, unit, unit>,
}

// The state-change descriptor itself lives in `LocalStateChangeDescriptor` —
// it is one of three implementations of a shared wire format and is covered by
// its own parity test, so it stays out of the bus.

// Opt-in NDJSON domain-event tap for the VS Code local platform runner (features
// plan Phase 9). Enabled when REVENTLESS_EVENT_TAP is set; off by default so normal
// runs stay quiet. Emitted from publishEvent so every event is captured with its
// real topic name (the EventTopic resource name consumers subscribe to) — no need
// to guess topic names from EventLog registry keys. Each line is sentinel-prefixed
// so the runner's line parser can pick it out of the platform's ANSI log noise on
// stdout. The emit is a plain Console.log, so it never perturbs publishEvent's
// subscriber-countdown delivery semantics.
// Read per publish (not once at import) so the runner can toggle it live and so
// hermetic tests can flip it between cases. The cost is one dict lookup per event.
let eventTapEnabled = () => NodeProcess.env->Dict.get("REVENTLESS_EVENT_TAP")->Option.isSome
let eventTapSeq = ref(0)
// Seed the in-memory tap counter from a persistent store's existing event count
// so the timeline's #N continues across process restarts / app switches instead
// of restarting at 1. Called once at platform startup for the sqlite backend.
let seedEventTapSeq = (n: int) => eventTapSeq := n
let emitEventTap = (~topic: string, ~service: string, ~payload: JSON.t) => {
  eventTapSeq := eventTapSeq.contents + 1
  let line =
    Dict.fromArray([
      ("event", JSON.Encode.string("domainEvent")),
      ("seq", JSON.Encode.int(eventTapSeq.contents)),
      ("topic", JSON.Encode.string(topic)),
      ("service", JSON.Encode.string(service)),
      ("payload", payload),
      ("ts", JSON.Encode.string(Date.make()->Date.toISOString)),
    ])->JSON.Encode.object
  Console.log("@@RVLESS_EVT@@ " ++ line->JSON.stringify)
}

module type T = {
  // Event fan-out: aggregate EventTopic → read model EventCollector
  let publishEvent: (string, string, ReventlessCore.Message.meta, JSON.t) => promise<unit>
  let subscribeToEvents: (
    string,
    (string, ReventlessCore.Message.meta, JSON.t) => promise<unit>,
  ) => unit

  /**
   * Stream-based alternative to subscribeToEvents.
   * Returns a scoped Effect that yields a Stream<queuedEvent> for the topic.
   * The subscriber count is incremented on scope open and decremented on scope close.
   * Callers MUST run msg.done_ after processing each message to unblock publishEvent.
   *
   * Use subscribeToEvents for simple fire-and-forget subscriptions.
   */
  let subscribeToEventStream: string => Effect.t<Stream.t<queuedEvent, unit, unit>, unit, unit>

  // Command dispatch: CommandTopic → aggregate command handler
  // Dispatches a single encoded command JSON {reference, commandJson}
  let dispatchCommand: (string, JSON.t) => promise<unit>
  let registerCommandHandler: (string, (JSON.t, unit) => promise<unit>) => unit

  // QueryDb registry: read model name → storage ops and scan function
  // Populated by LocalQueryDbStorage.Make(Bus) during component construction.
  let registerQueryDb: (string, ReventlessCore.QueryDb_Adapter.operations) => unit
  let getQueryDb: string => option<ReventlessCore.QueryDb_Adapter.operations>
  let registerQueryDbScan: (string, unit => array<JSON.t>) => unit
  let getQueryDbScan: string => option<unit => array<JSON.t>>
  // Stream variant: lazily creates a Stream from current storage contents.
  // Used by LocalQueryEngine to honour ~limit via Stream.take without loading all items.
  let registerQueryDbStream: (string, unit => Stream.t<JSON.t, string, unit>) => unit
  let getQueryDbStream: string => option<unit => Stream.t<JSON.t, string, unit>>
  // Indexed equality lookup: (field, value) → matching items. The SQLite backend
  // registers a closure that pushes the predicate down to a `json_extract` GSI
  // index instead of materialising + parsing the whole table; the in-memory
  // backend registers a scan+filter. The `{name}By{Index}` resolvers use this
  // when present and fall back to `getQueryDbScan` otherwise.
  let registerQueryDbIndexLookup: (string, (string, string) => array<JSON.t>) => unit
  let getQueryDbIndexLookup: string => option<(string, string) => array<JSON.t>>
  // Connection-list push-down: given the GraphQL args + derived capability +
  // label field, a backend may return a ready Relay connection object computed
  // entirely in storage (SQLite: json_extract predicates + ORDER BY … LIMIT), or
  // `None` when it can't serve that query shape — the resolver then falls back to
  // materialise + `QueryDbListQuery.run`. Only the SQLite backend registers one.
  let registerQueryDbListPage: (
    string,
    (
      ~argsDict: dict<JSON.t>,
      ~capability: ReventlessCore.GraphQL_FragmentGenerator.serverCapability,
      ~labelField: string,
      ~ownerScope: (string, string)=?,
      ~retiredScope: Reventless.OwnerScope.retiredScope=?,
    ) => option<JSON.t>,
  ) => unit
  let getQueryDbListPage: string => option<
    (
      ~argsDict: dict<JSON.t>,
      ~capability: ReventlessCore.GraphQL_FragmentGenerator.serverCapability,
      ~labelField: string,
      ~ownerScope: (string, string)=?,
      ~retiredScope: Reventless.OwnerScope.retiredScope=?,
    ) => option<JSON.t>,
  >

  // Event log replay registry: aggregate EventLog name → replay function (entityId → events)
  let registerEventLogReplay: (string, string => promise<array<JSON.t>>) => unit
  let getEventLogReplay: string => option<string => promise<array<JSON.t>>>

  // DCB event log read registry: DCB EventLog name → read function
  let registerDcbEventLogRead: (
    string,
    (
      ~query: Reventless.DcbTag.query,
      ~after: Reventless.DcbTag.sequencePosition=?,
    ) => promise<ReventlessCore.DcbEventLog_Adapter.rawReadResult>,
  ) => unit
  let getDcbEventLogRead: string => option<
    (
      ~query: Reventless.DcbTag.query,
      ~after: Reventless.DcbTag.sequencePosition=?,
    ) => promise<ReventlessCore.DcbEventLog_Adapter.rawReadResult>,
  >

  // Subscription push hooks — used by LocalGraphQL_SubscriptionResolvers to bridge
  // QueryDb writes and EventTopic publishes into a yoga PubSub for WebSocket delivery.
  //
  // Source B (state changes): QueryDbStorage_InMemory calls publishStateChange after
  //   every save/delete so subscription listeners receive a change descriptor matching
  //   the AWS StateTopic Lambda output: {changeKind, id, sortKeyValue?, seq, state?}.
  //   ~name is the QueryDb/ReadModel Spec.name; ~descriptor is built via
  //   `LocalStateChangeDescriptor.make`.
  //
  //   `changeKind` matches AWS, which reads it off the DynamoDB stream eventName:
  //   save() checks whether a visible row already held the key and emits "Added"
  //   or "Updated" accordingly, `delete()` emits "Removed". Without the "Added"
  //   arm a list view drops every row it doesn't already hold, so seeding into an
  //   empty read model looked like live updates were broken.
  let publishStateChange: (~name: string, ~descriptor: JSON.t) => unit
  let subscribeToStateChanges: (string, JSON.t => unit) => unit
  // All-changes variant: receives every publishStateChange with its read-model
  // name. Used by the local Events transport to bridge descriptors onto
  // `/default/{name}/{id}` channels without enumerating read models up front.
  let subscribeToAllStateChanges: ((~name: string, ~descriptor: JSON.t) => unit) => unit

  // Cross-plugin EP subscription registry.
  // EventCollectors register their handler once resolved; makePlatform subscribes
  // them to external EP EventTopics to wire cross-plugin Extension connections.
  let registerEventCollectorHandler: (string, (JSON.t, unit) => promise<unit>) => unit
  let subscribeEventCollectorToTopic: (string, string) => unit

  // Projection catch-up registry: collector name → its resolved JSON event
  // handler, registered only by projection-type collectors (the ReadModel
  // builders, via LocalEventCollectorChannel.MakeProjection). The SQLite
  // backend's startup catch-up (ProjectionCheckpoint.runCatchup) replays missed
  // stored events into these handlers; automation/translation collectors are
  // deliberately NOT in this registry so catch-up can never re-run side effects.
  let registerProjectionCatchupHandler: (string, (JSON.t, unit) => promise<unit>) => unit
  let projectionCatchupHandlers: unit => array<(string, (JSON.t, unit) => promise<unit>)>

  let reset: unit => unit
}

// Internal module type for bus configuration.
// capacity=None → unbounded hub (synchronous fan-out, no backpressure, 2-tick delivery).
// capacity=Some(n) → bounded hub (async publish with backpressure, 3-tick delivery).
// silent — when true, suppresses diagnostic warnings (e.g. missing command handlers).
module type BusConfig = {
  let capacity: option<int>
  let silent: bool
}

// Full implementation parameterised by BusConfig.
// Used by both Make (unbounded) and MakeBounded (bounded).
module Impl = (C: BusConfig): T => {
  let capacity = C.capacity

  // Per-topic PubSub hub for fan-out to all subscriber Queues.
  // Unbounded (capacity=None): synchronous fan-out, 2-tick delivery guarantee.
  // Bounded (capacity=Some(n)): async publish with backpressure, 3-tick delivery.
  let eventHubs: ref<dict<PubSub.t<queuedEvent>>> = ref(Dict.make())
  // Per-topic subscriber count — tracked manually because PubSub.size measures
  // buffered message count (always 0 for unbounded after delivery), not subscriber count.
  let subscriberCounts: ref<dict<int>> = ref(Dict.make())

  let commandHandlers: ref<dict<(JSON.t, unit) => promise<unit>>> = ref(Dict.make())
  // Per-channel pending command queues — drained when registerCommandHandler fires.
  let pendingCommandQueues: ref<dict<ref<array<JSON.t>>>> = ref(Dict.make())
  let queryDbRegistry: ref<dict<ReventlessCore.QueryDb_Adapter.operations>> = ref(Dict.make())
  let queryDbScanRegistry: ref<dict<unit => array<JSON.t>>> = ref(Dict.make())
  let queryDbStreamRegistry: ref<dict<unit => Stream.t<JSON.t, string, unit>>> = ref(Dict.make())
  let queryDbIndexLookupRegistry: ref<dict<(string, string) => array<JSON.t>>> = ref(Dict.make())
  let queryDbListPageRegistry: ref<
    dict<
      (
        ~argsDict: dict<JSON.t>,
        ~capability: ReventlessCore.GraphQL_FragmentGenerator.serverCapability,
        ~labelField: string,
        ~ownerScope: (string, string)=?,
        ~retiredScope: Reventless.OwnerScope.retiredScope=?,
      ) => option<JSON.t>,
    >,
  > = ref(Dict.make())
  let eventLogReplayRegistry: ref<dict<string => promise<array<JSON.t>>>> = ref(Dict.make())
  let dcbEventLogReadRegistry: ref<
    dict<
      (
        ~query: Reventless.DcbTag.query,
        ~after: Reventless.DcbTag.sequencePosition=?,
      ) => promise<ReventlessCore.DcbEventLog_Adapter.rawReadResult>,
    >,
  > = ref(Dict.make())

  // Create a new hub using the capacity from BusConfig.
  // None → unbounded (synchronous fan-out, no backpressure).
  // Some(n) → bounded (async publish, exerts backpressure when any subscriber is slow).
  let makeHub = (): PubSub.t<queuedEvent> =>
    switch capacity {
    | None => PubSub.unbounded()->Effect.runSync
    | Some(n) => PubSub.bounded(n)->Effect.runSync
    }

  let subscribeToEvents = (topicName, handler) => {
    let hub = switch eventHubs.contents->Dict.get(topicName) {
    | Some(h) => h
    | None =>
      let h: PubSub.t<queuedEvent> = makeHub()
      eventHubs.contents->Dict.set(topicName, h)
      h
    }
    // Increment count synchronously before starting the fiber — publishEvent reads
    // this count and must see it even if called immediately after subscribeToEvents.
    let n = subscriberCounts.contents->Dict.get(topicName)->Option.getOr(0)
    subscriberCounts.contents->Dict.set(topicName, n + 1)
    // Drain loop: subscribe to hub, consume messages via Stream.fromQueue → Stream.runForEach.
    // Effect.scoped manages the subscription lifecycle; PubSub.shutdown in reset() closes it.
    // The fiber runs synchronously up to the first Queue.take suspension, so PubSub.subscribe
    // registers before Effect.runFork returns.
    let drainLoop = Effect.scoped(
      PubSub.subscribe(hub)->Effect.flatMap(queue =>
        Stream.fromQueue(queue)->Stream.runForEach(msg =>
          // A throwing/rejecting handler must not (a) leave `done_` uncalled —
          // the publisher's countdown would never reach zero and every publish
          // on this topic would hang — nor (b) kill this drain fiber, which
          // would stop consuming while the subscriber stays counted, hanging all
          // future publishes too. So: convert a rejection into a typed error
          // (`tryPromise`), log-and-recover (`catchAll`) so the stream keeps
          // draining, and run `done_` via `ensuring` so the countdown always
          // advances regardless of outcome.
          Effect.tryPromise(~catch=e => e, () => handler(msg.service, msg.meta, msg.json))
          ->Effect.catchAll(err =>
            Effect.sync(() => Console.error2("[LocalBus] subscriber handler failed:", err))
          )
          ->Effect.ensuring(msg.done_)
        )
      ),
    )
    let _ = Effect.runFork(drainLoop)
  }

  let subscribeToEventStream = topicName => {
    let hub = switch eventHubs.contents->Dict.get(topicName) {
    | Some(h) => h
    | None =>
      let h: PubSub.t<queuedEvent> = makeHub()
      eventHubs.contents->Dict.set(topicName, h)
      h
    }
    // Acquire: increment subscriber count + subscribe to hub.
    // Release: decrement subscriber count + shut down the per-subscriber queue.
    // PubSub.subscribe's own scope management also removes the subscriber from the hub
    // when the outer Effect.scoped closes.
    Effect.acquireRelease(
      Effect.sync(() => {
        let n = subscriberCounts.contents->Dict.get(topicName)->Option.getOr(0)
        subscriberCounts.contents->Dict.set(topicName, n + 1)
      })->Effect.flatMap(_ => PubSub.subscribe(hub)),
      (queue, _exit) =>
        Effect.sync(() => {
          let n = subscriberCounts.contents->Dict.get(topicName)->Option.getOr(1)
          subscriberCounts.contents->Dict.set(topicName, n - 1)
        })->Effect.zipRight(Queue.shutdown(queue)),
    )->Effect.map(queue => Stream.fromQueue(queue))
  }

  let publishEvent = async (topicName, service, meta, json) => {
    if eventTapEnabled() {
      emitEventTap(~topic=topicName, ~service, ~payload=json)
    }
    switch eventHubs.contents->Dict.get(topicName) {
    | None => ()
    | Some(hub) =>
      let n = subscriberCounts.contents->Dict.get(topicName)->Option.getOr(0)
      if n == 0 {
        ()
      } else {
        // One Deferred for the whole publish call. The last subscriber to finish
        // resolves it via the countdown done_ Effect.
        let allDone: Deferred.t<unit, unit> = Deferred.make()->Effect.runSync
        let remaining = ref(n)
        // done_ runs inside each drain fiber's Effect chain (via Effect.zipRight).
        // It decrements remaining and — when reaching zero — resolves allDone.
        // IMPORTANT: done_ must NOT be called via Effect.runSync from a JS callback.
        // It must run within the Effect fiber so that Deferred.succeed operates in the
        // same runtime as Deferred.await_ below.
        let done_: Effect.t<unit, unit, unit> = Effect.sync(() => {
          remaining := remaining.contents - 1
        })->Effect.flatMap(_ =>
          if remaining.contents == 0 {
            Deferred.succeed(allDone, ())->Effect.map(_ => ())
          } else {
            Effect.succeed()
          }
        )
        let msg = {service, meta, json, done_}
        // Publish path is conditional on capacity:
        //   None (unbounded): Effect.runSync for publish (synchronous fan-out, 2-tick path).
        //   Some(_) (bounded): Effect.runPromise for publish (may suspend when queues full, 3-tick path).
        // Both paths wait for allDone to resolve (all subscribers finished).
        let publishAndWait: Effect.t<unit, unit, unit> = switch capacity {
        | None =>
          // Unbounded: publish synchronously inside Effect.sync so the fiber chain is uniform.
          // Effect.runSync keeps fan-out synchronous, preserving the 2-tick guarantee.
          Effect.sync(() => {
            let _ = PubSub.publish(hub, msg)->Effect.runSync
          })->Effect.zipRight(Deferred.await_(allDone))
        | Some(_) =>
          // Bounded: publish is an Effect that may suspend if any subscriber queue is full.
          // This provides backpressure: publishEvent suspends until a slow subscriber drains.
          PubSub.publish(hub, msg)->Effect.flatMap(_ => Deferred.await_(allDone))
        }
        let _ = await publishAndWait->Effect.runPromise
      }
    }
  }

  let dispatchCommand = async (channelName, json) => {
    switch commandHandlers.contents->Dict.get(channelName) {
    | Some(handler) => await handler(json, ())
    | None =>
      // Park the command — drained once registerCommandHandler fires for this channel.
      let queue = switch pendingCommandQueues.contents->Dict.get(channelName) {
      | Some(q) => q
      | None =>
        let q = ref([])
        pendingCommandQueues.contents->Dict.set(channelName, q)
        q
      }
      queue.contents->Array.push(json)
    }
  }

  let registerCommandHandler = (channelName, handler) => {
    commandHandlers.contents->Dict.set(channelName, handler)
    // Drain any commands that arrived before the handler was registered.
    switch pendingCommandQueues.contents->Dict.get(channelName) {
    | Some(queue) =>
      let pending = queue.contents
      queue.contents = []
      pending->Array.forEach(json => {
        let _ =
          handler(json, ())->Promise.catch(e => {
            Console.error2("[LocalBus] parked command handler failed:", e)
            Promise.resolve()
          })
      })
    | None => ()
    }
  }

  let registerQueryDb = (name, ops) => queryDbRegistry.contents->Dict.set(name, ops)
  let getQueryDb = name => queryDbRegistry.contents->Dict.get(name)
  let registerQueryDbScan = (name, scan) => queryDbScanRegistry.contents->Dict.set(name, scan)
  let getQueryDbScan = name => queryDbScanRegistry.contents->Dict.get(name)
  let registerQueryDbStream = (name, streamFn) =>
    queryDbStreamRegistry.contents->Dict.set(name, streamFn)
  let getQueryDbStream = name => queryDbStreamRegistry.contents->Dict.get(name)
  let registerQueryDbIndexLookup = (name, lookup) =>
    queryDbIndexLookupRegistry.contents->Dict.set(name, lookup)
  let getQueryDbIndexLookup = name => queryDbIndexLookupRegistry.contents->Dict.get(name)
  let registerQueryDbListPage = (name, listPage) =>
    queryDbListPageRegistry.contents->Dict.set(name, listPage)
  let getQueryDbListPage = name => queryDbListPageRegistry.contents->Dict.get(name)

  let registerEventLogReplay = (name, replay) =>
    eventLogReplayRegistry.contents->Dict.set(name, replay)
  let getEventLogReplay = name => eventLogReplayRegistry.contents->Dict.get(name)
  let registerDcbEventLogRead = (name, read) =>
    dcbEventLogReadRegistry.contents->Dict.set(name, read)
  let getDcbEventLogRead = name => dcbEventLogReadRegistry.contents->Dict.get(name)

  // Source B state-change hook — per QueryDb name, zero or more listeners.
  let stateChangeListeners: ref<dict<array<JSON.t => unit>>> = ref(Dict.make())
  let allStateChangeListeners: ref<array<(~name: string, ~descriptor: JSON.t) => unit>> = ref([])

  let subscribeToStateChanges = (name, callback) => {
    let listeners = stateChangeListeners.contents->Dict.get(name)->Option.getOr([])
    stateChangeListeners.contents->Dict.set(name, Array.concat(listeners, [callback]))
  }

  let subscribeToAllStateChanges = callback =>
    allStateChangeListeners.contents->Array.push(callback)

  let publishStateChange = (~name, ~descriptor) => {
    stateChangeListeners.contents
    ->Dict.get(name)
    ->Option.getOr([])
    ->Array.forEach(cb => cb(descriptor))
    allStateChangeListeners.contents->Array.forEach(cb => cb(~name, ~descriptor))
  }

  let eventCollectorHandlers: ref<dict<(JSON.t, unit) => promise<unit>>> = ref(Dict.make())
  let eventCollectorPendingTopics: ref<dict<array<string>>> = ref(Dict.make())

  // Cross-plugin subscriptions are fire-and-forget: the handler is started asynchronously
  // and done_ is called immediately. This prevents a deadlock where publishEvent on the
  // EP topic would block until the downstream aggregate command chain completes.
  let makeFireAndForgetHandler = handler => (_, _, json) => {
    let _ =
      handler(json, ())->Promise.catch(e => {
        Console.error2("[LocalBus] fire-and-forget handler failed:", e)
        Promise.resolve()
      })
    Promise.resolve()
  }

  let registerEventCollectorHandler = (ecName, handler) => {
    eventCollectorHandlers.contents->Dict.set(ecName, handler)
    switch eventCollectorPendingTopics.contents->Dict.get(ecName) {
    | Some(topics) =>
      topics->Array.forEach(topicName =>
        subscribeToEvents(topicName, makeFireAndForgetHandler(handler))
      )
      eventCollectorPendingTopics.contents->Dict.delete(ecName)
    | None => ()
    }
  }

  let subscribeEventCollectorToTopic = (ecName, topicName) => {
    switch eventCollectorHandlers.contents->Dict.get(ecName) {
    | Some(handler) => subscribeToEvents(topicName, makeFireAndForgetHandler(handler))
    | None =>
      let pending = eventCollectorPendingTopics.contents->Dict.get(ecName)->Option.getOr([])
      pending->Array.push(topicName)
      eventCollectorPendingTopics.contents->Dict.set(ecName, pending)
    }
  }

  let projectionCatchupRegistry: ref<dict<(JSON.t, unit) => promise<unit>>> = ref(Dict.make())

  let registerProjectionCatchupHandler = (name, handler) =>
    projectionCatchupRegistry.contents->Dict.set(name, handler)

  let projectionCatchupHandlers = () => projectionCatchupRegistry.contents->Dict.toArray

  let reset = () => {
    // Shut down all hubs — PubSub.shutdown interrupts Stream.fromQueue consumers,
    // causing Stream.runForEach to complete and Effect.scoped to close the subscription.
    let shutdownAll =
      eventHubs.contents
      ->Dict.valuesToArray
      ->Array.map(hub => PubSub.shutdown(hub))
      ->Effect.all({"concurrency": "unbounded"})
      ->Effect.map(_ => ())
    let _ = Effect.runSync(shutdownAll)
    eventHubs := Dict.make()
    subscriberCounts := Dict.make()
    commandHandlers := Dict.make()
    pendingCommandQueues := Dict.make()
    queryDbRegistry := Dict.make()
    queryDbScanRegistry := Dict.make()
    queryDbStreamRegistry := Dict.make()
    queryDbIndexLookupRegistry := Dict.make()
    queryDbListPageRegistry := Dict.make()
    eventLogReplayRegistry := Dict.make()
    dcbEventLogReadRegistry := Dict.make()
    stateChangeListeners := Dict.make()
    allStateChangeListeners := []
    eventCollectorHandlers := Dict.make()
    eventCollectorPendingTopics := Dict.make()
    projectionCatchupRegistry := Dict.make()
  }
}

// Backward-compatible unbounded bus (2-tick delivery guarantee).
// All existing LocalBus.Make() call sites work without modification.
module Make = (): T => {
  include Impl({
    let capacity: option<int> = None
    let silent = false
  })
}

// Silent unbounded bus — suppresses diagnostic warnings. Use in tests.
module MakeSilent = (): T => {
  include Impl({
    let capacity: option<int> = None
    let silent = true
  })
}

// Bounded bus (Phase G): each subscriber queue has a fixed capacity.
// publishEvent suspends when any subscriber's queue is full — providing backpressure.
// Resolves in 3 microtask ticks (1 more than unbounded).
// Usage: module TestBus = LocalBus.MakeBounded({let capacity = 2})
module MakeBounded = (
  C: {
    let capacity: int
  },
): T => {
  include Impl({
    let capacity: option<int> = Some(C.capacity)
    let silent = false
  })
}
