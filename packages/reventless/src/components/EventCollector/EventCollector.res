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

type eventsHandler = array<Js.Json.t> => Js.Promise.t<unit>

module type T = {
  let make: (
    ~name: string,
    ~eventTopics: EventTopic.allOutputs,
    ~eventsHandler: eventsHandler,
    ~memorySize: int=?,
    ~timeout: int=?,
    ~policy1: Pulumi.Output.t<option<string>>,
    ~policy2: Pulumi.Output.t<option<string>>,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component
}
