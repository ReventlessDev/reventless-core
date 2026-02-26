let make: ReventlessCore.EventTopic_Adapter.publisherMaker = (
  ~name as _,
  ~storageResources,
  ~opts as _,
) => {
  let storageResource = storageResources->Util.DynamoDbStream.findResource

  {
    resources: [
      storageResource.service
      ->Pulumi.Output.apply(service =>
        if service == AWS.DynamoDbStream.service {
          storageResource->Util_DynamoDbStream.toStreamResource
        } else {
          JsError.throwWithMessage(
            "EventTopicPublisher_DynamoDbStream cannot connect to EventLogStorage_" ++ service,
          )
        }
      )
      ->ReventlessCore.Adapter.outputToResource,
    ],
    publishJson: Pulumi.Output.make((_, _, _) => Promise.resolve()), // ignore
  }
}
