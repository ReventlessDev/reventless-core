open PulumiAws

let make: ReventlessCore.Counter_Adapter.handlerMaker = (
  ~name,
  ~referencesName,
  ~referencesDb,
  ~countsName,
  ~countsDb,
  ~counterHandler,
  ~opts,
) => {
  let referencesDbResource = referencesDb.resources->Util.DynamoDbStream.findResource
  let referencesStream = referencesDbResource->Util.DynamoDbStream.toStreamResource
  let countsDbResource = countsDb.resources->Util.DynamoDbStream.findResource
  let countsStream = countsDbResource->Util.DynamoDbStream.toStreamResource

  let eventHandlerLambda = Lambda.CallbackFunction.make(
    ~name,
    ~args=Lambda.CallbackFunction.Args.make(
      ~callback=CounterHandler_DynamoDbStream_Runtime.handleStreamEvent(
        ~referencesStream,
        ~countsStream,
        ~counterHandler,
        ...
      ),
    ),
    ~opts,
  )

  let subscribe = (sourceName, source) =>
    Util_EventSourceMapping.subscribe(
      ~lambda=eventHandlerLambda->Pulumi.Output.make,
      ~targetName=name,
      ~sourceName,
      ~source,
      ~opts,
    )

  let _ = subscribe(referencesName, referencesStream)
  let _ = subscribe(countsName, countsStream)

  {
    addToCounterTarget: counterTarget =>
      CounterHandler_DynamoDbStream_Runtime.addToCounterTarget(countsDbResource, counterTarget),
  }
}
