let make: Reventless.StateTopic.Adapter.publisherMaker =
  (~name, ~opts as _, ~allQueryDbs) => {
    let queryDbResource =
      allQueryDbs
      ->Reventless.Util.ReadModel.queryDbStorageResources(
          name->Js.String2.substring(
            ~from=0,
            ~to_=
              name->Js.String2.indexOf(
                ReadModel->Reventless.ComponentType.toName,
              ),
          ),
        )
      ->Reventless.Util.Adapter.findResource(Util.DynamoDbStream.service);

    {
      resource:
        queryDbResource##service
        ->Pulumi.Output.apply(service =>
            if (service == Util_DynamoDbStream.service) {
              queryDbResource->Util_DynamoDbStream.toStreamResource;
            } else {
              Js.Exn.raiseError(
                "StateTopicPublisher_DynamoDbStream cannot connect to QueryDbStorage_"
                ++ service,
              );
            }
          )
        ->Reventless.Adapter.outputToResource,
    };
  };
