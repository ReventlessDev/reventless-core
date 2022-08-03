open Reventless;
open ComponentType;

let make: StateTopic.Adapter.publisherMaker =
  (~name, ~opts as _, ~resources) => {
    let queryDbResource =
      resources
      ->Reventless.Util.ReadModel.queryDbStorageResource(
          None,
          name->Js.String2.substring(
            ~from=0,
            ~to_=name->Js.String2.indexOf(ReadModel->toName),
          ),
        )
      ->Belt.Option.getExn;

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
        ->Adapter.outputToResource,
    };
  };
