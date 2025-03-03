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

type rec subscribe<'callbackEvent, 'context> = (
  ~name: string,
  ~eventTopics: EventTopic.allOutputs,
  ~channel: channel<'callbackEvent, 'context>,
  ~runtime: Runtime.environment,
  ~opts: Pulumi.ComponentResource.options,
) => array<ReventlessSpec.Adapter.resource>
and channel<'callbackEvent, 'context> = {
  resources: array<ReventlessSpec.Adapter.resource>,
  enqueueEvent: Pulumi.Output.t<enqueueEvent>,
  handleChannelEvent: jsonEventsHandler => Pulumi.Output.t<
    Runtime.eventHandler<'callbackEvent, 'context, unit>,
  >,
  subscribe: subscribe<'callbackEvent, 'context>,
}

module type T = {
  type callbackEvent

  let subscribe: (
    ~name: string,
    ~eventTopics: EventTopic.allOutputs,
    ~channel: channel<callbackEvent, 'context>,
    ~runtime: Runtime.environment,
    ~opts: Pulumi.ComponentResource.options,
  ) => array<ReventlessSpec.Adapter.resource>

  let makeHandler: (
    ~channel: channel<callbackEvent, 'context>,
    ~eventsHandler: jsonEventsHandler,
  ) => Pulumi.Output.t<Runtime.eventHandler<callbackEvent, 'context, unit>>

  let make: (~name: string, ~opts: Pulumi.ComponentResource.options) => component

  let channel: component => channel<callbackEvent, 'context>
}
