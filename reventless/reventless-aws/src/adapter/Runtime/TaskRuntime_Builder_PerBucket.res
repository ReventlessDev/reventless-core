module RuntimeEnvironment = RuntimeEnvironment.Lambda
module TaskBucket = TaskBucket.S3

type context = PulumiAws.Lambda.context
type callbackEvent = TaskBucket.callbackEvent
type runtimeParts = Util.Lambda.runtimeParts

type bundledTaskBucketInfo = {
  callbackModulePath: string,
  publishToAggregatesQueueUrls: dict<Pulumi.Output.t<string>>,
}

let bundledTaskBucketInfos: dict<bundledTaskBucketInfo> = Dict.make()

let registerTaskBucket = (~bucketName, ~callbackModulePath, ~publishToAggregatesQueueUrls) =>
  bundledTaskBucketInfos->Dict.set(
    bucketName,
    {callbackModulePath, publishToAggregatesQueueUrls},
  )

let forBucketCallback = (
  ~handler as _,
  ~connect,
  ~memorySize=4096,
  ~timeout=600,
  ~name,
  task: ReventlessCore.Task.component,
) => {
  let resource = task->ReventlessCore.Component.toPulumiResource
  let fullName = resource.name->Option.getOr("UnnamedTask") ++ name

  switch bundledTaskBucketInfos->Dict.get(name) {
  | Some(info) =>
    let factoryModulePath =
      "@reventlessdev/reventless-aws/src/adapter/Runtime/TaskHandlerFactory.mjs"
    let requestContextModulePath =
      "@reventlessdev/reventless-core/src/RequestContext.res.mjs"

    let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
    let publishToAggregatesEnvVars: dict<string> = Dict.make()

    info.publishToAggregatesQueueUrls->Dict.forEachWithKey((queueUrlOutput, aggName) => {
      let envVar = `PUBLISH_${aggName}_QUEUE_URL`
      envVars->Dict.set(envVar, queueUrlOutput->Pulumi.Output.asInput)
      publishToAggregatesEnvVars->Dict.set(aggName, envVar)
    })

    let entryPointCode = Util_EntryPoint.generateTaskBucketEntryPoint({
      name: fullName,
      callbackModulePath: info.callbackModulePath,
      factoryModule: factoryModulePath,
      requestContextModule: requestContextModulePath,
      publishToAggregatesEnvVars,
    })

    let runtime = RuntimeEnvironment_Lambda.makeBundledFromEntryPoint(
      ~name=fullName,
      ~entryPointCode,
      ~envVars,
      ~memorySize,
      ~timeout,
      ~opts={Pulumi.ComponentResource.parent: resource},
    )

    connect(~runtime)
  | None =>
    Console.warn(
      `TaskRuntime_Builder_PerBucket: no bundled info registered for bucket "${name}"`,
    )
  }
}

let finish = () => ()
