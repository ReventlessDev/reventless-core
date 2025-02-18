let make: Reventless.CommandTopic_Adapter.remoteChannelMaker = resources => {
  remotePublish: resources
  ->Util.SQS_Runtime.findUnwrappedResource
  ->Util_SQS_Runtime.toRuntimeQueue
  ->(CommandTopicChannel_SQS_Runtime.publishJsons(Util.SQS_Runtime.service, ...)),
}
