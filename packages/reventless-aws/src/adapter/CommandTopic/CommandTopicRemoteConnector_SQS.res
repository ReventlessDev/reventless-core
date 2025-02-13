let make: Reventless.CommandTopic_Adapter.remoteConnectorMaker = resources => {
  remotePublish: resources->Pulumi.Output.apply(resources =>
    resources
    ->Util.SQS_Runtime.findUnwrappedResource
    ->Util_SQS_Runtime.toRuntimeQueue
    ->(CommandTopicConnector_SQS_Runtime.publishJsons(Util.SQS_Runtime.service, ...))
  ),
}
