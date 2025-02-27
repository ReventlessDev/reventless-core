type channelMaker<'callbackEvent, 'context> = (
  ~name: string,
  ~opts: Pulumi.ComponentResource.options=?,
) => CommandTopic.channel<'callbackEvent, 'context>

module type Channel = {
  type callbackEvent
  let make: channelMaker<callbackEvent, 'context>
}

type remoteChannel = {remotePublish: CommandTopic.publishJsons}
type remoteChannelMaker = array<Reventless.Adapter.unwrappedResource> => remoteChannel

module type RemoteChannel = {
  let make: remoteChannelMaker
}
