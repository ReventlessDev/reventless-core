module CommandTopicChannel = CommandTopicChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type bundledExtensionPointInfo = {
  specModulePath: string,
  mappingsModulePath: string,
  publishToAggregatesQueueUrls: dict<Pulumi.Output.t<string>>,
}

let bundledInfos: dict<bundledExtensionPointInfo> = Dict.make()

let registerExtensionPoint = (
  ~name,
  ~specModulePath,
  ~mappingsModulePath,
  ~publishToAggregatesQueueUrls,
) =>
  bundledInfos->Dict.set(
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
  let matchedInfo = switch bundledInfos->Dict.get(epName) {
  | Some(_) as hit => hit
  | None =>
    bundledInfos
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

    let factoryModulePath =
      "@reventlessdev/reventless-aws/src/adapter/Runtime/ExtensionPointHandlerFactory.mjs"
    let requestContextModulePath =
      "@reventlessdev/reventless-core/src/RequestContext.res.mjs"

    let name = commandTopicResource.name->ReventlessCore.ComponentType.nameOpt(
      ReventlessCore.CommandTopic.componentType,
    )
    let opts = {Pulumi.ComponentResource.parent: commandTopicResource}

    let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
    envVars->Dict.set("EP_QUEUE_URL", queue.id->Pulumi.Output.asInput)
    envVars->Dict.set("EP_QUEUE_ARN", queue.arn->Pulumi.Output.asInput)

    let publishToAggregatesEnvVars: dict<string> = Dict.make()
    info.publishToAggregatesQueueUrls->Dict.forEachWithKey((queueUrlOutput, aggName) => {
      let envVar = `PTA_${aggName}_QUEUE_URL`
      envVars->Dict.set(envVar, queueUrlOutput->Pulumi.Output.asInput)
      publishToAggregatesEnvVars->Dict.set(aggName, envVar)
    })

    let registration: Util_EntryPoint.extensionPointRegistration = {
      specModulePath: info.specModulePath,
      mappingsModulePath: info.mappingsModulePath,
      queueUrlEnvVar: "EP_QUEUE_URL",
      queueArnEnvVar: "EP_QUEUE_ARN",
      publishToAggregatesEnvVars,
    }

    let entryPointCode = Util_EntryPoint.generateExtensionPointEntryPoint({
      name: epName,
      handler: registration,
      factoryModule: factoryModulePath,
      requestContextModule: requestContextModulePath,
    })

    let runtime = RuntimeEnvironment_Lambda.makeBundledFromEntryPoint(
      ~name,
      ~entryPointCode,
      ~envVars,
      ~memorySize,
      ~timeout,
      ~opts,
    )
    connect(~runtime)
  | None =>
    Console.warn(
      `ExtensionPointRuntime_Builder_PerExtensionPoint: no bundled info for ${epName}`,
    )
  }
}
