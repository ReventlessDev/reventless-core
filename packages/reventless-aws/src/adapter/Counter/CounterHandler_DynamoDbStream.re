open PulumiAws;
open Reventless.Util.ReadModel;

let make: Reventless.Counter.Adapter.handlerMaker =
  (~name, ~referencesName, ~countsName, ~counterHandler, ~opts, ~resources) => {
    let referencesDb =
      resources
      ->queryDbStorageResource(None, referencesName)
      ->Belt.Option.getExn;
    let referencesStream = referencesDb->Util_DynamoDbStream.toStreamResource;
    let countsDb =
      resources->queryDbStorageResource(None, countsName)->Belt.Option.getExn;
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
