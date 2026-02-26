type rec connect<'callbackEvent, 'context, 'channelParts, 'runtimeParts> = (
  ~name: string,
  ~channel: channel<'callbackEvent, 'context, 'channelParts, 'runtimeParts>,
  ~runtime: Runtime.environment<'runtimeParts>,
  ~resources: array<Reventless.Adapter.resource>,
  ~opts: Pulumi.ComponentResource.options,
) => array<Reventless.Adapter.resource>
and channel<'callbackEvent, 'context, 'channelParts, 'runtimeParts> = {
  parts: 'channelParts,
  resources: array<Reventless.Adapter.resource>,
  publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
  handleChannelEvent: CommandTopic.jsonCommandsHandler => Pulumi.Output.t<
    Runtime.eventHandler<'callbackEvent, 'context, unit>,
  >,
  connect: connect<'callbackEvent, 'context, 'channelParts, 'runtimeParts>,
}

@set
external setChannel: (
  Component.t<CommandTopic.t, CommandTopic.outputs, 'operations>,
  channel<'callbackEvent, 'context, 'channelParts, 'runtimeParts>,
) => unit = "channel"
@get
external channel: Component.t<CommandTopic.t, CommandTopic.outputs, 'operations> => channel<
  'callbackEvent,
  'context,
  'channelParts,
  'runtimeParts,
> = "channel"

type channelMaker<'callbackEvent, 'context, 'channelParts, 'runtimeParts> = (
  ~name: string,
  ~opts: Pulumi.ComponentResource.options=?,
) => channel<'callbackEvent, 'context, 'channelParts, 'runtimeParts>

module type Channel = {
  type callbackEvent
  type runtimeParts
  type channelParts
  let make: channelMaker<callbackEvent, 'context, channelParts, runtimeParts>
}

type remoteChannel = {
  resources: array<ReventlessCore.Adapter.resolvedResource>,
  remotePublish: CommandTopic.publishJsons,
}
type remoteChannelMaker = array<ReventlessCore.Adapter.resolvedResource> => remoteChannel

module type RemoteChannel = {
  let make: remoteChannelMaker
}
