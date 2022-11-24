open PulumiAws;

let make: Reventless.Counter.Adapter.handlerMaker =
  (~name, ~allQueryDbs, ~referencesName, ~countsName, ~counterHandler, ~opts) => {
    let referencesDb =
      allQueryDbs
      ->Reventless.Util.ReadModel.queryDbStorageResources(referencesName)
      ->Reventless.Util.Adapter.findResource(Util.DynamoDbStream.service);
    let referencesStream = referencesDb->Util_DynamoDbStream.toStreamResource;

    let countsDb =
      allQueryDbs
      ->Reventless.Util.ReadModel.queryDbStorageResources(countsName)
      ->Reventless.Util.Adapter.findResource(Util.DynamoDbStream.service);
    let countsStream = countsDb->Util_DynamoDbStream.toStreamResource;

    let eventHandlerLambda =
      Lambda.CallbackFunction.make(
        ~name,
        ~args=
          Lambda.CallbackFunction.Args.make(
            ~callback=
              CounterHandler_DynamoDbStream_Runtime.handleStreamEvent(
                ~referencesStream,
                ~countsStream,
                ~counterHandler,
              ),
            (),
          ),
        ~opts,
        (),
      );

    let subscribe = (sourceName, source) =>
      Util_EventSourceMapping.subscribe(
        ~lambda=eventHandlerLambda->Pulumi.Output.make,
        ~targetName=name,
        ~sourceName,
        ~source,
        ~opts,
        (),
      );

    let _ = subscribe(referencesName, referencesStream);
    let _ = subscribe(countsName, countsStream);

    {
      addToCounterTarget:
        countsDb->CounterHandler_DynamoDbStream_Runtime.addToCounterTarget,
    };
  };
