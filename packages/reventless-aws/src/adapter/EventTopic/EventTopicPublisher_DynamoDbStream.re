let make: Reventless.EventTopic.Adapter.publisherMaker =
  (~name as _, ~storageResources, ~opts as _) => {
    let storageResource =
      storageResources->Reventless.Util.Adapter.findResource(
        Util_DynamoDbStream.service,
      );

    {
      resources: [|
        storageResource##service
        ->Pulumi.Output.apply(service =>
            if (service == Util_DynamoDbStream.service) {
              storageResource->Util_DynamoDbStream.toStreamResource;
            } else {
              Js.Exn.raiseError(
                "EventTopicPublisher_DynamoDbStream cannot connect to EventLogStorage_"
                ++ service,
              );
            }
          )
        ->Reventless.Adapter.outputToResource,
      |],
      publish: (. _, _, _) => Js.Promise.resolve() // ignore publish
    };
  };
