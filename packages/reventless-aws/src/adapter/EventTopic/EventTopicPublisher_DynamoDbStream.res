let make: Reventless.EventTopic_Adapter.publisherMaker = (
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
          Js.Exn.raiseError(
            "EventTopicPublisher_DynamoDbStream cannot connect to EventLogStorage_" ++ service,
          )
        }
      )
      ->Reventless.Adapter.outputToResource,
    ],
    publishJson: Pulumi.Output.make((_, _, _) => Js.Promise.resolve()), // ignore
  }
}
