open Reventless;
open ComponentType;

let make: EventTopic.Adapter.publisherMaker =
  (~name, ~opts as _) => {
    let eventLogResource =
      name
      ->Js.String2.substring(
          ~from=0,
          ~to_=name->Js.String2.indexOf(Aggregate->toName),
        )
      ->Reventless.EventLog.Adapter.getResource;

    {
      resource:
        if (eventLogResource##service == Util_DynamoDbStream.service) {
          eventLogResource->Util_DynamoDbStream.toStreamResource;
        } else {
          Js.Exn.raiseError(
            "EventTopicPublisher_DynamoDbStream cannot connect to EventLogStorage_"
            ++
            eventLogResource##service,
          );
        },
      publish: (. _, _, _) => Js.Promise.resolve() // ignore publish
    };
  };
