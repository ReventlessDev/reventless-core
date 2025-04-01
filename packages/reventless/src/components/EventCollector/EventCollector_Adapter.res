type rec connect<'callbackEvent, 'context, 'channelParts, 'runtimeParts> = (
  ~name: string,
  ~eventTopics: EventTopic.allOutputs,
  ~channel: channel<'callbackEvent, 'context, 'channelParts, 'runtimeParts>,
  ~runtime: Runtime.environment<'runtimeParts>,
  ~resources: array<ReventlessSpec.Adapter.resource>,
  ~opts: Pulumi.ComponentResource.options,
) => array<ReventlessSpec.Adapter.resource>
and channel<'callbackEvent, 'context, 'channelParts, 'runtimeParts> = {
  parts: 'channelParts,
  resources: array<ReventlessSpec.Adapter.resource>,
  enqueueEvent: Pulumi.Output.t<EventCollector.enqueueEvent>,
  handleChannelEvent: EventCollector.jsonEventsHandler => Pulumi.Output.t<
    Runtime.eventHandler<'callbackEvent, 'context, unit>,
  >,
  connect: connect<'callbackEvent, 'context, 'channelParts, 'runtimeParts>,
}

@set
external setChannel: (
  EventCollector.component,
  channel<'callbackEvent, 'context, 'channelParts, 'runtimeParts>,
) => unit = "channel"
@get
external channel: EventCollector.component => channel<
  'callbackEvent,
  'context,
  'channelParts,
  'runtimeParts,
> = "channel"

type channelMaker<'callbackEvent, 'context, 'channelParts, 'runtimeParts> = (
  ~name: string,
  ~opts: Pulumi.ComponentResource.options,
) => channel<'callbackEvent, 'context, 'channelParts, 'runtimeParts>

module type Channel = {
  type callbackEvent
  type channelParts
  type runtimeParts
  let make: channelMaker<callbackEvent, 'context, channelParts, runtimeParts>
}
