let componentType = ComponentType.EventCollector

type enqueueEvent = (
  /* ~delay: */ int,
  /* ~id: */ string,
  /* ~message: */ string,
) => Js.Promise.t<unit>

type t
type outputs = {name: string, resources: array<ReventlessSpec.Adapter.resource>}
type operations = {enqueueEvent: enqueueEvent}
type component = Component.t<t, outputs, operations>

type jsonEventsHandler = array<Js.Json.t> => Js.Promise.t<unit>

module type T = {
  type callbackEvent

  let subscribe: (
    ~name: string,
    ~eventTopics: EventTopic.allOutputs,
    ~eventCollector: component,
    ~runtime: Runtime.environment,
    ~opts: Pulumi.ComponentResource.options,
  ) => unit

  let makeHandler: (
    ~eventCollector: component,
    ~eventsHandler: jsonEventsHandler,
  ) => Pulumi.Output.t<Runtime.eventHandler<callbackEvent, 'context, unit>>

  let make: (~name: string, ~opts: Pulumi.ComponentResource.options) => component
}
