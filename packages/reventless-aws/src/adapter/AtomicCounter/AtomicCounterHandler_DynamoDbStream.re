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

    let _eventSourceMappings =
      readModelNames
      ->Belt.Array.map(readModelName =>
          (
            readModelName,
            resources->Reventless.Util.ReadModel.queryDbStorageResource(
              readModelName,
            ),
          )
        )
      ->Belt.Array.map(((sourceName, topic)) =>
          Util_EventSourceMapping.subscribe(
            ~lambda=eventHandlerLambda->Pulumi.Output.make,
            ~targetName=name,
            ~sourceName,
            ~topic,
            ~opts,
          )
        );

    ();
  };
