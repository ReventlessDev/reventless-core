let make: ReventlessCore.CommandTopic_Adapter.remoteChannelMaker = resources => {
  resources,
  remotePublish: resources
  ->Util.SQS.findResolvedResource
  ->Util_SQS_Runtime.toRuntimeQueue
  ->CommandTopicChannel_SQS_Runtime.publishJsons(AWS.SQS, ...),
}
