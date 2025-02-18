type channelMaker = (
  ~name: string,
  ~opts: Pulumi.ComponentResource.options=?,
) => CommandTopic.channel

module type Channel = {
  let make: channelMaker
}

type remoteChannel = {remotePublish: CommandTopic.publishJsons}
type remoteChannelMaker = array<Reventless.Adapter.unwrappedResource> => remoteChannel

module type RemoteChannel = {
  let make: remoteChannelMaker
}
