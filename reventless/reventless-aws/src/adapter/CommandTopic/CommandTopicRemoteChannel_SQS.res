let make: Reventless.CommandTopic_Adapter.remoteChannelMaker = resources => {
  resources,
  remotePublish: resources
  ->Util.SQS.findUnwrappedResource
  ->Util_SQS_Runtime.toRuntimeQueue
  ->CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS, ...),
}
