type bundledCounterInfo = {
  specModulePath: string,
  mappingsModulePath: string,
  publishQueueUrl: Pulumi.Output.t<string>,
}

let bundledCounterInfos: dict<bundledCounterInfo> = Dict.make()

let registerCounter = (~counterName, ~specModulePath, ~mappingsModulePath, ~publishQueueUrl) =>
  bundledCounterInfos->Dict.set(
    counterName,
    {specModulePath, mappingsModulePath, publishQueueUrl},
  )

let make: ReventlessCore.Counter_Adapter.handlerMaker = (
  ~name,
  ~referencesName,
  ~referencesDb,
  ~countsName,
  ~countsDb,
  ~counterHandler as _,
  ~opts,
) => {
  let referencesDbResource = referencesDb.resources->Util.DynamoDbStream.findResource
  let referencesStream = referencesDbResource->Util.DynamoDbStream.toStreamResource
  let countsDbResource = countsDb.resources->Util.DynamoDbStream.findResource
  let countsStream = countsDbResource->Util.DynamoDbStream.toStreamResource

  switch bundledCounterInfos->Dict.get(name) {
  | Some(info) =>
    let factoryModulePath =
      "@reventlessdev/reventless-aws/src/adapter/Runtime/CounterHandlerFactory.mjs"
    let requestContextModulePath =
      "@reventlessdev/reventless-core/src/RequestContext.res.mjs"

    let envVars: dict<Pulumi.Input.t<string>> = Dict.make()

    let countsTableName = (countsDb.resources->Array.getUnsafe(0)).name
    envVars->Dict.set("COUNTER_COUNTS_TABLE", countsTableName->Pulumi.Output.asInput)
    envVars->Dict.set("COUNTER_PUBLISH_QUEUE_URL", info.publishQueueUrl->Pulumi.Output.asInput)
    envVars->Dict.set("COUNTER_REFERENCES_STREAM_ARN", referencesStream.urn->Pulumi.Output.asInput)
    envVars->Dict.set("COUNTER_COUNTS_STREAM_ARN", countsStream.urn->Pulumi.Output.asInput)

    let entryPointCode = Util_EntryPoint.generateCounterEntryPoint({
      name,
      specModulePath: info.specModulePath,
      mappingsModulePath: info.mappingsModulePath,
      factoryModule: factoryModulePath,
      requestContextModule: requestContextModulePath,
      countsTableEnvVar: "COUNTER_COUNTS_TABLE",
      publishQueueUrlEnvVar: "COUNTER_PUBLISH_QUEUE_URL",
      referencesStreamArnEnvVar: "COUNTER_REFERENCES_STREAM_ARN",
      countsStreamArnEnvVar: "COUNTER_COUNTS_STREAM_ARN",
    })

    let componentOpts: Pulumi.ComponentResource.options = {parent: ?opts.parent}

    let runtime = RuntimeEnvironment_Lambda.makeBundledFromEntryPoint(
      ~name,
      ~entryPointCode,
      ~envVars,
      ~memorySize=1024,
      ~timeout=30,
      ~opts=componentOpts,
    )

    let lambda = runtime.parts.lambda

    let subscribe = (sourceName, source) =>
      Util_EventSourceMapping.subscribe(
        ~lambda=lambda,
        ~targetName=name,
        ~sourceName,
        ~source,
        ~opts,
      )

    let _ = subscribe(referencesName, referencesStream)
    let _ = subscribe(countsName, countsStream)

    {
      ReventlessCore.Counter_Adapter.addToCounterTarget: counterTarget =>
        CounterHandler_DynamoDbStream_Runtime.addToCounterTarget(countsDbResource, counterTarget),
    }
  | None =>
    Console.warn(
      `CounterHandler_DynamoDbStream: no bundled info registered for "${name}"`,
    )
    {
      addToCounterTarget: async _counterTarget => (),
    }
  }
}
