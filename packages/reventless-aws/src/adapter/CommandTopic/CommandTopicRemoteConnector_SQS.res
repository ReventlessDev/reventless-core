let make: Reventless.CommandTopic.Adapter.remoteConnectorMaker = resources => {
  remotePublish: resources
  ->Util.SQS_Runtime.findResource
  ->Util.SQS_Runtime.fromResource
  ->Util_SQS_Runtime.toRuntimeQueue
  ->(CommandTopicConnector_SQS_Runtime.publish(Util.SQS_Runtime.service, ...)),
}
