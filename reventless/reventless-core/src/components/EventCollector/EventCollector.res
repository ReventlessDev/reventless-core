let componentType = ComponentType.EventCollector

type enqueueEvent = Reventless.EventCollector.enqueueEvent

type t
type outputs = Reventless.EventCollector.outputs
type operations = {enqueueEvent: enqueueEvent}
type component = Component.t<t, outputs, operations>

/** Stream-based internal handler type. All events in a batch arrive as a single Stream. */
type jsonEventsHandler = Stream.t<JSON.t, string, unit> => Effect.t<unit, string, unit>

/**
 * Backward-compatibility bridge: wraps an array-based handler as a `jsonEventsHandler`.
 * Collects the stream into an array, then awaits the legacy promise handler.
 */
let fromArrayHandler: (array<JSON.t> => promise<unit>) => jsonEventsHandler =
  arrayHandler => stream =>
    stream
    ->Stream.runCollect
    ->Effect.flatMap(arr => Effect.promise(() => arrayHandler(arr)))

module type T = {
  type callbackEvent
  type runtimeParts

  let connect: (
    ~eventTopics: EventTopic.allOutputs,
    ~resources: array<Reventless.Adapter.resource>,
    ~runtime: Runtime.environment<runtimeParts>,
    component,
  ) => unit

  let makeHandler: (
    ~eventCollector: component,
    ~eventsHandler: jsonEventsHandler,
  ) => Pulumi.Output.t<Runtime.eventHandler<callbackEvent, 'context, unit>>

  let make: (
    ~name: string,
    ~eventTopics: EventTopic.allOutputs,
    ~opts: Pulumi.ComponentResource.options,
  ) => component
}
