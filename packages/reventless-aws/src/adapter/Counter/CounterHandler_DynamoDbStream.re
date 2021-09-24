open PulumiAws;
open Reventless.Util.ReadModel;

let make: Reventless.Counter.Adapter.handlerMaker =
  (~name, ~referencesName, ~countsName, ~counterHandler, ~opts, ~resources) => {
    let referencesDb = resources->queryDbStorageResource(referencesName);
    let countsDb = resources->queryDbStorageResource(countsName);

    let eventHandlerLambda =
      Lambda.CallbackFunction.make(
        ~name,
        ~args=
          Lambda.CallbackFunction.Args.make(
            ~callback=
              CounterHandler_DynamoDbStream_Runtime.handleStreamEvent(
                ~referencesDb,
                ~countsDb,
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
      );

    let _ = subscribe(referencesName, referencesDb);
    let _ = subscribe(countsName, countsDb);

    {
      setCounterTarget:
        countsDb->CounterHandler_DynamoDbStream_Runtime.setCounterTarget,
    };
  };
