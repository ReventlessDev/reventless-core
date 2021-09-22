open PulumiAws;

let make: Reventless.AtomicCounter.Adapter.handlerMaker =
  (~name, ~readModelNames, ~handleEvents, ~opts, ~resources) => {
    let eventHandlerLambda =
      Lambda.CallbackFunction.make(
        ~name,
        ~args=
          Lambda.CallbackFunction.Args.make(
            ~callback=
              EventCollectorConnector_DynamoDbStream_Runtime.handleStreamEvent(
                handleEvents,
              ),
            (),
          ),
        ~opts,
        (),
      );

    let dynamoDbStreamTopics =
      readModelNames->Belt.Array.map(readModelName =>
        resources->Reventless.Util.ReadModel.queryDbStorageResource(
          readModelName,
        )
      );

    let _eventSourceMappings =
      dynamoDbStreamTopics->Belt.Array.map(
        Util_EventSourceMapping.subscribe(eventHandlerLambda, name, opts),
      );

    ();
  };
