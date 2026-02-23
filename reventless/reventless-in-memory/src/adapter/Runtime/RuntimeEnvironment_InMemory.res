// In-memory runtime environment.
// Instead of creating Lambda functions, stores the handler in a ref so it can be
// invoked directly (synchronously in Pulumi mock mode during tests).

type event = JSON.t
type context = unit
type parts = {handlerRef: ref<option<(JSON.t, unit) => promise<unit>>>}

// Coerce a polymorphic handler to return promise<unit> so we can call it from the bus.
// The return value is discarded — we only await for side effects.
external asUnitHandler: ((JSON.t, unit) => promise<'r>) => (JSON.t, unit) => promise<unit> =
  "%identity"

let make = (
  ~name as _: string,
  ~handler: Pulumi.Output.t<Reventless.Runtime.eventHandler<event, context, 'result>>,
  ~memorySize as _=1024,
  ~timeout as _=30,
  ~opts as _=?,
): Reventless.Runtime.environment<parts> => {
  let handlerRef: ref<option<(JSON.t, unit) => promise<unit>>> = ref(None)
  // In Pulumi mock mode, Output.apply is synchronous — handlerRef is set immediately.
  let _ = handler->Pulumi.Output.apply(h => {
    handlerRef := Some(h->asUnitHandler)
  })
  {parts: {handlerRef: handlerRef}, resources: []}
}

let groupBySource = (event: JSON.t) => {
  let dict: dict<JSON.t> = Dict.make()
  dict->Dict.set("inmemory", event)
  dict
}

external asEventHandler: 'a => Reventless.Runtime.eventHandler<event, context, 'r> = "%identity"
