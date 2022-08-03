open Reventless;
open ComponentType;

let make: EventTopic.Adapter.publisherMaker =
  (~name, ~opts as _, ~resources) => {
    let eventLogResource =
      resources->Reventless.Util.Aggregate.eventLogStorageResource(
        name->Js.String2.substring(
          ~from=0,
          ~to_=name->Js.String2.indexOf(Aggregate->toName),
        ),
      );

    {
      resources: [|
        eventLogResource##service
        ->Pulumi.Output.apply(service =>
            if (service == Util_DynamoDbStream.service) {
              eventLogResource->Util_DynamoDbStream.toStreamResource;
            } else {
              Js.Exn.raiseError(
                "EventTopicPublisher_DynamoDbStream cannot connect to EventLogStorage_"
                ++ service,
              );
            }
          )
        ->Adapter.outputToResource,
      |],
      publish: (. _, _, _) => Js.Promise.resolve() // ignore publish
    };
  };
