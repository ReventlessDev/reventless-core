// In-memory CommandTopic remote channel — satisfies CommandTopic_Adapter.RemoteChannel.
// Dispatches "remote" commands directly to the in-memory Bus.

module Make = (Bus: InMemory_Bus.T) => {
  let make: ReventlessCore.CommandTopic_Adapter.remoteChannelMaker = resources => {
    resources,
    remotePublish: async jsons => {
      let _ =
        await jsons
        ->Array.map(async (cmdJson: Reventless.Message.commandJson) => {
          // Encode the same way CommandTopicChannel_InMemory does
          let body = JSON.Encode.object(
            Dict.fromArray([
              ("id", JSON.Encode.string(cmdJson.id)),
              (
                "meta",
                cmdJson.meta->Reventless.Util_Sury.toJson(Reventless.Message.metaSchema),
              ),
              ("command", cmdJson.commandJson),
            ]),
          )
          // Dispatch to the first resource's name (the channel name)
          let channelName = switch resources {
          | [] => ""
          | resources => (resources->Array.getUnsafe(0)).name
          }
          await Bus.dispatchCommand(channelName, body)
        })
        ->Promise.all
    },
  }
}
