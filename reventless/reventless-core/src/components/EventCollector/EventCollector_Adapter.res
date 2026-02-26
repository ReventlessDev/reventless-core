type channel<'callbackEvent, 'context, 'channelParts> = {
  parts: 'channelParts,
  resources: array<Reventless.Adapter.resource>,
  enqueueEvent: Pulumi.Output.t<EventCollector.enqueueEvent>,
  handleChannelEvent: EventCollector.jsonEventsHandler => Pulumi.Output.t<
    Runtime.eventHandler<'callbackEvent, 'context, unit>,
  >,
}

type channelSpec<'callbackEvent, 'context, 'channelParts> = {
  channel: channel<'callbackEvent, 'context, 'channelParts>,
  eventTopics: EventTopic.allOutputs,
  resources: array<Reventless.Adapter.resource>,
}

type connect<'callbackEvent, 'context, 'channelParts, 'runtimeParts> = (
  ~name: string,
  ~channelSpecs: array<channelSpec<'callbackEvent, 'context, 'channelParts>>,
  ~runtime: Runtime.environment<'runtimeParts>,
  ~opts: Pulumi.ComponentResource.options,
) => array<Reventless.Adapter.resource>

type channelMaker<'callbackEvent, 'context, 'channelParts> = (
  ~name: string,
  ~eventTopics: EventTopic.allOutputs,
  ~opts: Pulumi.ComponentResource.options,
) => channel<'callbackEvent, 'context, 'channelParts>

@set
external setChannel: (
  EventCollector.component,
  channel<'callbackEvent, 'context, 'channelParts>,
) => unit = "channel"
@get
external channel: EventCollector.component => channel<'callbackEvent, 'context, 'channelParts> =
  "channel"

module type Channel = {
  type callbackEvent
  type channelParts
  type runtimeParts

  let make: channelMaker<callbackEvent, 'context, channelParts>
  let connect: connect<callbackEvent, 'context, channelParts, runtimeParts>
}
