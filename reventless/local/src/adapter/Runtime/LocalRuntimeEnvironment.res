// In-memory runtime environment.
// Instead of creating Lambda functions, stores the handler in a Deferred so consumers
// block until the handler is registered — eliminating the ref<option> race condition.
//
// subscriptionLatch is opened by EventCollectorChannel.connect once subscriptions are
// registered. Callers can await it before publishing to guarantee delivery.

type event = JSON.t
type context = unit
type handler = (JSON.t, unit) => promise<unit>
type parts = {
  handlerDeferred: Deferred.t<handler, unit>,
  subscriptionLatch: Latch.t,
}

// Coerce a polymorphic handler to return promise<unit> so we can call it from the bus.
// The return value is discarded — we only await for side effects.
external asUnitHandler: ((JSON.t, unit) => promise<'r>) => (JSON.t, unit) => promise<unit> =
  "%identity"

let make = (
  ~name as _: string,
  ~handler: Pulumi.Output.t<ReventlessCore.Runtime.eventHandler<event, context, 'result>>,
  ~memorySize as _=1024,
  ~timeout as _=30,
  ~opts as _=?,
): ReventlessCore.Runtime.environment<parts> => {
  let handlerDeferred = Deferred.make()->Effect.runSync
  let subscriptionLatch = Effect.makeLatch(false)->Effect.runSync
  // In Pulumi mock mode, Output.apply resolves in ~2 microtask ticks.
  // Use runPromise (not runSync) so fiber wake-ups are properly scheduled.
  let _ = handler->Pulumi.Output.apply(h => {
    Deferred.succeed(handlerDeferred, h->asUnitHandler)->Effect.runPromise->ignore
  })
  {parts: {handlerDeferred, subscriptionLatch}, resources: []}
}

let groupBySource = (event: JSON.t) => {
  let dict: dict<JSON.t> = Dict.make()
  dict->Dict.set("inmemory", event)
  dict
}

let extractMetaField = (event: event, field) =>
  event
  ->JSON.Decode.object
  ->Option.flatMap(obj => obj->Dict.get("meta"))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(meta => meta->Dict.get(field))
  ->Option.flatMap(JSON.Decode.string)

let extractCorrelationId = (event: event) => event->extractMetaField("correlationId")
let extractCausationId = (event: event) => event->extractMetaField("causationId")

// In-process dispatch: the message is handed over the moment it is published, so
// dispatch time *is* send time and there is no queue to dwell in. A handler that
// computes `now - timestamp` therefore measures its own processing latency here
// and end-to-end latency on a queue-backed platform — same expression, both
// answers correct for their transport.
let extractSentTimestamp = (_event: event) => Some(Date.now())

// No redelivery in-process — the bus calls each handler once.
let extractRetryCount = (_event: event) => Some(1)

external asEventHandler: 'a => ReventlessCore.Runtime.eventHandler<event, context, 'r> = "%identity"
external asEffectHandler: 'a => ReventlessCore.Runtime.effectHandler<event, context, 'r, 'error> =
  "%identity"
