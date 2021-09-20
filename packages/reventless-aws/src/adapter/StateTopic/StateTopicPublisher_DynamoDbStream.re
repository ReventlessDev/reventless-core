open Reventless;
open ComponentType;

let make: StateTopic.Adapter.publisherMaker =
  (~name, ~opts as _, ~resources) => {
    let queryDbResource =
      resources->Reventless.Util.ReadModel.queryDbStorageResource(
        name->Js.String2.substring(
          ~from=0,
          ~to_=name->Js.String2.indexOf(ReadModel->toName),
        ),
      );

    {
      resource:
        if (queryDbResource##service == Util_DynamoDbStream.service) {
          queryDbResource->Util_DynamoDbStream.toStreamResource;
        } else {
          Js.Exn.raiseError(
            "StateTopicPublisher_DynamoDbStream cannot connect to QueryDbStorage_"
            ++
            queryDbResource##service,
          );
        },
    };
  };
