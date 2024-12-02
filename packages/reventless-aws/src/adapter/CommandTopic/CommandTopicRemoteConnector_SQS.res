let make: Reventless.CommandTopic.Adapter.remoteConnectorMaker = commandTopicOutputs => {
  Js.log2(
    "CommandTopicRemoteConnector_SQS.make: commandTopic.resources:",
    commandTopicOutputs.resources,
  )
  {
    remotePublish: commandTopicOutputs.resources
    ->Reventless.Message.log(
      "CommandTopicRemoteConnector_SQS.remotePublish: commandTopic.resources:",
    )
    ->Util.SQS_Runtime.findResource
    ->Reventless.Message.log("CommandTopicRemoteConnector_SQS.remotePublish: found resource:")
    ->Util.SQS_Runtime.fromResource
    ->Reventless.Message.log("CommandTopicRemoteConnector_SQS.remotePublish: queue:")
    ->(CommandTopicConnector_SQS_Runtime.publish(Util.SQS_Runtime.service, ...)),
  }
}
