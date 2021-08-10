open Reventless;
open ComponentType;

let make: EventTopic.Adapter.publisherMaker =
  (~name, ~opts as _) => {
    resource:
      name
      ->Js.String2.substring(
          ~from=0,
          ~to_=name->Js.String2.indexOf(Aggregate->toName),
        )
      ->Reventless.EventLog.Adapter.getResource,
    publish: (. _, _, _) => Js.Promise.resolve() // ignore publish
  };
