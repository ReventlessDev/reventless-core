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
    let envVars: dict<Pulumi.Input.t<string>> = Dict.make()

    // Build publishToAggregates env var mapping
    let publishToAggregatesEnvVars: dict<string> = Dict.make()
    info.publishToAggregatesQueueUrls->Dict.forEachWithKey((queueUrlOutput, aggName) => {
      let envVar = `PUBLISH_${aggName}_QUEUE_URL`
      envVars->Dict.set(envVar, queueUrlOutput->Pulumi.Output.asInput)
      publishToAggregatesEnvVars->Dict.set(aggName, envVar)
    })

    // Build HANDLER_CONFIG JSON
    let callbackModule =
      info.callbackModulePath->JSON.stringifyAny->Option.getOr(`""`)
    let publishToAggregatesJson =
      publishToAggregatesEnvVars
      ->Dict.toArray
      ->Array.map(((aggName, envVar)) =>
        `${aggName->JSON.stringifyAny->Option.getOr(`""`)}: ${envVar->JSON.stringifyAny->Option.getOr(`""`)}`
      )
      ->Array.join(",")

    let handlerConfigJson =
      `{"callbackModule":${callbackModule},"publishToAggregates":{${publishToAggregatesJson}}}`
    envVars->Dict.set("HANDLER_CONFIG", handlerConfigJson->Pulumi.Input.make)

    // Build code asset
    let packageDirs: dict<string> = Dict.make()
    let pkg = Util_Bundle.extractPackageName(info.callbackModulePath)
    packageDirs->Dict.set(pkg, Util_Bundle.resolvePackageRoot(pkg))

    let reExportCode = `export { handler } from "@reventlessdev/reventless-aws/src/adapter/Runtime/TaskBucketEntryPoint.mjs";`

    let archiveContents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
    archiveContents->Dict.set(
      "index.mjs",
      Pulumi.Asset.stringAsset(reExportCode)->Pulumi.Archive.assetToAssetOrArchive,
    )
    packageDirs->Dict.forEachWithKey((pkgRoot, pkgName) => {
      archiveContents->Dict.set(
        `node_modules/${pkgName}`,
        Util_Bundle.createFilteredPackageArchive(pkgRoot)
        ->Pulumi.Archive.archiveToAssetOrArchive,
      )
    })

    let code = Pulumi.Archive.assetArchive(archiveContents)
    let sourceCodeHash = Util_Bundle.hashString(
      reExportCode ++ packageDirs->Dict.keysToArray->Array.join(","),
    )

    let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
      ~name=fullName,
      ~code,
      ~sourceCodeHash,
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
