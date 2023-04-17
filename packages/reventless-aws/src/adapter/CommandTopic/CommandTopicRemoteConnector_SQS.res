let make: Reventless.CommandTopic.Adapter.remoteConnectorMaker = commandTopicOutputs => {
  remotePublish: commandTopicOutputs["resources"]
  ->Belt.Array.map(Reventless.AdapterDeploytime.unsafeUnwrapResource)
  ->Util.SQS_Runtime.findUnwrappedResource
  ->Reventless.Adapter.unwrappedToResource
  ->Util.SQS_Runtime.fromResource
  ->CommandTopicConnector_SQS_Runtime.publish(Util.SQS_Runtime.service),
}
