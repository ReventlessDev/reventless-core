type rec subscribe<'callbackEvent, 'context> = (
  ~name: string,
  ~channel: channel<'callbackEvent, 'context>,
  ~runtime: Runtime.environment,
  ~opts: Pulumi.ComponentResource.options,
) => array<ReventlessSpec.Adapter.resource>
and channel<'callbackEvent, 'context> = {
  resources: array<ReventlessSpec.Adapter.resource>,
  publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
  handleChannelEvent: CommandTopic.jsonCommandsHandler => Pulumi.Output.t<
    Runtime.eventHandler<'callbackEvent, 'context, unit>,
  >,
  subscribe: subscribe<'callbackEvent, 'context>,
}

@set
external setChannel: (
  Component.t<CommandTopic.t, CommandTopic.outputs, 'operations>,
  channel<'callbackEvent, 'context>,
) => unit = "channel"
@get
external channel: Component.t<CommandTopic.t, CommandTopic.outputs, 'operations> => channel<
  'callbackEvent,
  'context,
> = "channel"

type channelMaker<'callbackEvent, 'context> = (
  ~name: string,
  ~opts: Pulumi.ComponentResource.options=?,
) => channel<'callbackEvent, 'context>

module type Channel = {
  type callbackEvent
  let make: channelMaker<callbackEvent, 'context>
}

type remoteChannel = {remotePublish: CommandTopic.publishJsons}
type remoteChannelMaker = array<Reventless.Adapter.unwrappedResource> => remoteChannel

module type RemoteChannel = {
  let make: remoteChannelMaker
}
