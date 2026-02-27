// Shared in-memory event and command bus.
// Each Platform.Make() creates a fresh isolated bus — no global state, no test interference.
//
// Event delivery uses Effect Queue + Deferred completion signals:
//
//  subscribeToEvents — creates an unbounded Queue for the subscriber and starts a
//    drain fiber (via Effect.runFork). The drain fiber loops forever: take message,
//    call the callback, resolve the completion Deferred.
//
//  publishEvent — for each subscriber, synchronously creates a Deferred and offers
//    {payload, signal} to their Queue (via Effect.runSync, avoiding the overhead of
//    Effect.all fiber-forking), then awaits all signals via Promise.all. publishEvent
//    resolves only after every subscriber has finished (exactly 2 microtask ticks).
//
//  reset — shuts down all subscriber Queues (interrupting their drain fibers via
//    Queue.take interruption), then clears all four registries.

// Message offered to a subscriber's Queue. The signal Deferred is resolved by the
// drain loop after the callback returns, so the publisher can await completion.
//
// NOTE on scheduling hops: Deferred.make() and Queue.offer() are both pure synchronous
// Effect values — they can be executed with Effect.runSync. This avoids the extra fiber-
// forking overhead of Effect.all({concurrency: "unbounded"}) (which uses forEachConcurrentDiscard
// internally and adds 4 scheduling hops). By using Effect.runSync for the synchronous parts
// and Promise.all for the signal awaiting, publishEvent resolves in 2 microtask ticks —
// matching the 2 `await Promise.resolve()` calls in the test helpers.
type queuedEvent = {
  service: string,
  meta: ReventlessCore.Message.meta,
  json: JSON.t,
  signal: Deferred.t<unit, unit>,
}

// Per-subscriber state — just the Queue that receives messages from publishers.
type subscriber = {queue: Queue.t<queuedEvent>}

module type T = {
  // Event fan-out: aggregate EventTopic → read model EventCollector
  let publishEvent: (string, string, ReventlessCore.Message.meta, JSON.t) => promise<unit>
  let subscribeToEvents: (string, (string, ReventlessCore.Message.meta, JSON.t) => promise<unit>) => unit

  // Command dispatch: CommandTopic → aggregate command handler
  // Dispatches a single encoded command JSON {reference, commandJson}
  let dispatchCommand: (string, JSON.t) => promise<unit>
  let registerCommandHandler: (string, (JSON.t, unit) => promise<unit>) => unit

  // QueryDb registry: read model name → storage ops and scan function
  // Populated by QueryDbStorage_InMemory.Make(Bus) during component construction.
  let registerQueryDb: (string, ReventlessCore.QueryDb_Adapter.operations) => unit
  let getQueryDb: string => option<ReventlessCore.QueryDb_Adapter.operations>
  let registerQueryDbScan: (string, unit => array<JSON.t>) => unit
  let getQueryDbScan: string => option<unit => array<JSON.t>>

  let reset: unit => unit
}

module Make = (): T => {
  let eventSubscribers: ref<dict<array<subscriber>>> = ref(Dict.make())
  let commandHandlers: ref<dict<(JSON.t, unit) => promise<unit>>> = ref(Dict.make())
  let queryDbRegistry: ref<dict<ReventlessCore.QueryDb_Adapter.operations>> = ref(Dict.make())
  let queryDbScanRegistry: ref<dict<unit => array<JSON.t>>> = ref(Dict.make())

  let subscribeToEvents = (topicName, handler) => {
    let queue: Queue.t<queuedEvent> = Queue.unbounded()->Effect.runSync
    // Drain loop: take one message, call the callback, resolve the completion signal,
    // then immediately loop. Effect.forever repeats until Queue.take is interrupted
    // (which happens when Queue.shutdown is called in reset).
    let drainLoop =
      Queue.take(queue)
      ->Effect.flatMap(msg =>
        Effect.promise(() => handler(msg.service, msg.meta, msg.json))
        ->Effect.zipRight(Deferred.succeed(msg.signal, ())->Effect.map(_ => ()))
      )
      ->Effect.forever
    // runFork starts the drain loop as a background fiber in the global Effect runtime.
    let _ = Effect.runFork(drainLoop)
    let existing = eventSubscribers.contents->Dict.get(topicName)->Option.getOr([])
    eventSubscribers.contents->Dict.set(topicName, existing->Array.concat([{queue: queue}]))
  }

  let publishEvent = async (topicName, service, meta, json) => {
    let subscribers = eventSubscribers.contents->Dict.get(topicName)->Option.getOr([])
    // For each subscriber: synchronously create a Deferred signal and offer the message
    // to their Queue (both are pure synchronous Effect values), then collect the signal
    // Promises. We use Effect.runSync here to avoid the extra fiber-forking overhead of
    // Effect.all({concurrency: "unbounded"}) — that path adds 4 scheduling hops because
    // forEachConcurrentDiscard creates a processingFiber + child fibers via scheduleTask.
    // Using runSync + Promise.all reduces to 2 scheduling hops, so tests only need
    // 2 `await Promise.resolve()` ticks after advancing fake timers.
    let signalPromises = subscribers->Array.map(sub => {
      let signal = Deferred.make()->Effect.runSync
      let _ = Queue.offer(sub.queue, {service, meta, json, signal})->Effect.runSync
      Deferred.await_(signal)->Effect.runPromise
    })
    let _ = await signalPromises->Promise.all
  }

  let dispatchCommand = async (channelName, json) => {
    switch commandHandlers.contents->Dict.get(channelName) {
    | Some(handler) => await handler(json, ())
    | None => Console.log2("InMemory_Bus: no command handler for channel", channelName)
    }
  }

  let registerCommandHandler = (channelName, handler) => {
    commandHandlers.contents->Dict.set(channelName, handler)
  }

  let registerQueryDb = (name, ops) => queryDbRegistry.contents->Dict.set(name, ops)
  let getQueryDb = name => queryDbRegistry.contents->Dict.get(name)
  let registerQueryDbScan = (name, scan) => queryDbScanRegistry.contents->Dict.set(name, scan)
  let getQueryDbScan = name => queryDbScanRegistry.contents->Dict.get(name)

  let reset = () => {
    // Shut down all subscriber queues — Queue.shutdown interrupts any fibers blocked
    // on Queue.take, causing their drain loops to exit cleanly.
    let shutdownAll =
      eventSubscribers.contents
      ->Dict.valuesToArray
      ->Array.flatMap(subs => subs->Array.map(sub => Queue.shutdown(sub.queue)))
      ->Effect.all({"concurrency": "unbounded"})
      ->Effect.map(_ => ())
    let _ = Effect.runSync(shutdownAll)
    eventSubscribers := Dict.make()
    commandHandlers := Dict.make()
    queryDbRegistry := Dict.make()
    queryDbScanRegistry := Dict.make()
  }
}
