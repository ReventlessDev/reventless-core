let make: Reventless.EventTopic.Adapter.publisherMaker =
  (~name, ~opts as _) => {
    resource: name->Reventless.EventLog.Adapter.getResource,
    publish: (. _, _, _) => Js.Promise.resolve() // ignore publish
  };
