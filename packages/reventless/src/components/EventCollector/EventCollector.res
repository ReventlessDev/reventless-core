let componentType = ComponentType.EventCollector

type enqueueEvent = (/* ~delay: */ int, /* ~id: */ string, /* ~message: */ string) => promise<unit>

type t
type outputs = {name: string, resources: array<ReventlessSpec.Adapter.resource>}
type operations = {enqueueEvent: enqueueEvent}
type component = Component.t<t, outputs, operations>

type jsonEventsHandler = array<JSON.t> => promise<unit>

module type T = {
  type callbackEvent
  type runtimeParts

  let connect: (
    ~eventTopics: EventTopic.allOutputs,
    ~resources: array<ReventlessSpec.Adapter.resource>,
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
