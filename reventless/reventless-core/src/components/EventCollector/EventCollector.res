let componentType = ComponentType.EventCollector

type enqueueEvent = ReventlessInfra.EventCollector.enqueueEvent

type t
type outputs = ReventlessInfra.EventCollector.outputs
type operations = {enqueueEvent: enqueueEvent}
type component = Component.t<t, outputs, operations>

/** Stream-based internal handler type. All events in a batch arrive as a single Stream. */
type jsonEventsHandler = Stream.t<JSON.t, string, unit> => Effect.t<unit, string, unit>

module type T = {
  type callbackEvent
  type runtimeParts

  let connect: (
    ~eventTopics: EventTopic.allOutputs,
    ~resources: array<ReventlessInfra.Adapter.resource>,
    ~runtime: Runtime.environment<runtimeParts>,
    component,
  ) => unit

  let makeHandler: (
    ~eventCollector: component,
    ~jsonEventsHandler: jsonEventsHandler,
  ) => Pulumi.Output.t<Runtime.eventHandler<callbackEvent, 'context, unit>>

  let make: (
    ~name: string,
    ~eventTopics: EventTopic.allOutputs,
    ~opts: Pulumi.ComponentResource.options,
  ) => component
}
