type rec subscribe<'callbackEvent, 'context> = (
  ~name: string,
  ~eventTopics: EventTopic.allOutputs,
  ~channel: channel<'callbackEvent, 'context>,
  ~runtime: Runtime.environment,
  ~opts: Pulumi.ComponentResource.options,
) => array<ReventlessSpec.Adapter.resource>
and channel<'callbackEvent, 'context> = {
  resources: array<ReventlessSpec.Adapter.resource>,
  enqueueEvent: Pulumi.Output.t<EventCollector.enqueueEvent>,
  handleChannelEvent: EventCollector.jsonEventsHandler => Pulumi.Output.t<
    Runtime.eventHandler<'callbackEvent, 'context, unit>,
  >,
  subscribe: subscribe<'callbackEvent, 'context>,
}

@set
external setChannel: (EventCollector.component, channel<'callbackEvent, 'context>) => unit =
  "channel"
@get
external channel: EventCollector.component => channel<'callbackEvent, 'context> = "channel"

type channelMaker<'callbackEvent, 'context> = (
  ~name: string,
  ~opts: Pulumi.ComponentResource.options,
) => channel<'callbackEvent, 'context>

module type Channel = {
  type callbackEvent
  let make: channelMaker<callbackEvent, 'context>
}
