module CommandTopicChannel = CommandTopicChannel.SQS_Sync
module RuntimeEnvironment = RuntimeEnvironment.Lambda

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type extensionPointInfo = {
  specModulePath: string,
  mappingsModulePath: string,
  publishToAggregatesQueueUrls: dict<Pulumi.Output.t<string>>,
}

let extensionPointInfos: dict<extensionPointInfo> = Dict.make()

let registerExtensionPoint = (
  ~name,
  ~specModulePath,
  ~mappingsModulePath,
  ~publishToAggregatesQueueUrls,
) =>
  extensionPointInfos->Dict.set(
    name,
    {specModulePath, mappingsModulePath, publishToAggregatesQueueUrls},
  )

let forCommandTopic: ReventlessCore.Runtime.forComponent<
  ReventlessCore.Runtime.effectHandler<
    CommandTopicChannel.callbackEvent,
    context,
    unit,
    string,
  >,
  runtimeParts,
  ReventlessCore.CommandTopic.component<'op>,
> = (
  ~handler as _,
  ~connect,
  ~memorySize=1024,
  ~timeout=30,
  commandTopic,
) => {
  let commandTopicResource = commandTopic->ReventlessCore.Component.toPulumiResource
  let epName = commandTopicResource.name->Option.getOr("Unnamed")

  // Look up by exact name first, then by suffix match (EP names get prefixed
  // by the Plugin name and dots are stripped, e.g. "Ordering.Orders" → "OrderingOrdersExtPoint").
  let matchedInfo = switch extensionPointInfos->Dict.get(epName) {
  | Some(_) as hit => hit
  | None =>
    extensionPointInfos
    ->Dict.toArray
    ->Array.find(((registeredName, _)) =>
      epName->String.includes(registeredName->String.replaceAll(".", ""))
    )
    ->Option.map(((_, info)) => info)
  }
  switch matchedInfo {
  | Some(info) =>
    let channel = commandTopic->ReventlessCore.CommandTopic_Adapter.channel
    let channelParts: Util.SQS.channelParts = Obj.magic(channel.parts)
    let queue = channelParts.queue

    let name = commandTopicResource.name->ReventlessCore.ComponentType.nameOpt(
      ReventlessCore.CommandTopic.componentType,
    )
    let opts = {Pulumi.ComponentResource.parent: commandTopicResource}

    // Build HANDLER_CONFIG with publishToAggregates mapping aggregate names to env var names
    let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
    envVars->Dict.set("EP_QUEUE_URL", queue.id->Pulumi.Output.asInput)

    let publishToAggregatesEnvVars: dict<string> = Dict.make()
    info.publishToAggregatesQueueUrls->Dict.forEachWithKey((queueUrlOutput, aggName) => {
      let envVar = `PTA_${aggName}_QUEUE_URL`
      envVars->Dict.set(envVar, queueUrlOutput->Pulumi.Output.asInput)
      publishToAggregatesEnvVars->Dict.set(aggName, envVar)
    })

    let specModule = info.specModulePath->JSON.stringifyAny->Option.getOr(`""`)
    let mappingsModule = info.mappingsModulePath->JSON.stringifyAny->Option.getOr(`""`)
    let publishToAggregatesJson =
      publishToAggregatesEnvVars
      ->Dict.toArray
      ->Array.map(((aggName, envVar)) =>
        `${aggName->JSON.stringifyAny->Option.getOr(`""`)}: ${envVar->JSON.stringifyAny->Option.getOr(`""`)}`
      )
      ->Array.join(",")

    let handlerConfigJson =
      queue.id
      ->Pulumi.Output.apply(queueUrl =>
        `{"specModule":${specModule},"mappingsModule":${mappingsModule},"queueUrl":"${queueUrl}","publishToAggregates":{${publishToAggregatesJson}}}`
      )
    envVars->Dict.set("HANDLER_CONFIG", handlerConfigJson->Pulumi.Output.asInput)

    // Collect unique user packages for the code asset
    let packageDirs: dict<string> = Dict.make()
    let specPkg = Util_Bundle.extractPackageName(info.specModulePath)
    let mappingsPkg = Util_Bundle.extractPackageName(info.mappingsModulePath)
    packageDirs->Dict.set(specPkg, Util_Bundle.resolvePackageRoot(specPkg))
    packageDirs->Dict.set(mappingsPkg, Util_Bundle.resolvePackageRoot(mappingsPkg))

    let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
      ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/ExtensionPointEntryPoint.mjs",
      ~packageDirs,
    )

    let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
      ~name,
      ~code,
      ~sourceCodeHash,
      ~envVars,
      ~memorySize,
      ~timeout,
      ~opts,
    )
    connect(~runtime)
  | None =>
    Console.warn(
      `ExtensionPointRuntime_Builder_PerExtensionPoint: no handler registered for ${epName}`,
    )
  }
}

let finish = () => ()
