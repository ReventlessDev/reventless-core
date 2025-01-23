let make: Reventless.CommandTopic.Adapter.remoteConnectorMaker = resources => {
  remotePublish: resources
  ->Util.SQS_Runtime.findResource
  ->Util.SQS_Runtime.fromResource
  ->(CommandTopicConnector_SQS_Runtime.publish(Util.SQS_Runtime.service, ...)),
}
