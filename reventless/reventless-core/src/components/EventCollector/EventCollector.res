let componentType = ComponentType.EventCollector

type enqueueEvent = Reventless.EventCollector.enqueueEvent

type t
type outputs = Reventless.EventCollector.outputs
type operations = {enqueueEvent: enqueueEvent}
type component = Component.t<t, outputs, operations>

type jsonEventsHandler = array<JSON.t> => promise<unit>

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
