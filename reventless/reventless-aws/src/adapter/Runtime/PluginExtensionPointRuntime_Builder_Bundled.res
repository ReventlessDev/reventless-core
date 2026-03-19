module CommandTopicChannel = CommandTopicChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type bundledPluginEPInfo = {
  publishToAggregatesQueueUrls: dict<Pulumi.Output.t<string>>,
  pluginReadModelTableName: option<Pulumi.Output.t<string>>,
  schedulerRoleArn: option<Pulumi.Output.t<string>>,
}

let bundledInfo: ref<bundledPluginEPInfo> = ref({
  publishToAggregatesQueueUrls: Dict.make(),
  pluginReadModelTableName: None,
  schedulerRoleArn: None,
})

let registerBundledPluginExtensionPoint = (
  ~publishToAggregatesQueueUrls=Dict.make(),
  ~pluginReadModelTableName=?,
  ~schedulerRoleArn=?,
  (),
) =>
  bundledInfo := {
    publishToAggregatesQueueUrls,
    pluginReadModelTableName,
    schedulerRoleArn,
  }

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
  let info = bundledInfo.contents

  let channel = commandTopic->ReventlessCore.CommandTopic_Adapter.channel
  let channelParts: Util.SQS.channelParts = Obj.magic(channel.parts)
  let queue = channelParts.queue

  let factoryModulePath = Util_Bundle.resolveModule(
    "@reventlessdev/reventless-aws/src/adapter/Runtime/BundledPluginExtensionPointHandlerFactory.mjs",
  )
  let requestContextModulePath = Util_Bundle.resolveModule(
    "@reventlessdev/reventless-core/src/RequestContext.res.mjs",
  )

  let name = commandTopicResource.name->ReventlessCore.ComponentType.nameOpt(
    ReventlessCore.CommandTopic.componentType,
  )
  let opts = {Pulumi.ComponentResource.parent: commandTopicResource}

  let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
  envVars->Dict.set("EP_QUEUE_URL", queue.id->Pulumi.Output.asInput)
  envVars->Dict.set("EP_QUEUE_ARN", queue.arn->Pulumi.Output.asInput)

  // Plugin ReadModel table — placeholder if not available (queryEngine will fail same as non-bundled)
  envVars->Dict.set(
    "PLUGIN_RM_TABLE",
    switch info.pluginReadModelTableName {
    | Some(tableName) => tableName->Pulumi.Output.asInput
    | None => "NOT_AVAILABLE"->Pulumi.Output.make->Pulumi.Output.asInput
    },
  )

  // Scheduler role ARN — placeholder if not available (scheduler will be stubbed at runtime)
  envVars->Dict.set(
    "SCHEDULER_ROLE_ARN",
    switch info.schedulerRoleArn {
    | Some(arn) => arn->Pulumi.Output.asInput
    | None => "NOT_AVAILABLE"->Pulumi.Output.make->Pulumi.Output.asInput
    },
  )

  // Use EP's own CommandTopic queue as the scheduler target (for disconnect timeout events)
  envVars->Dict.set("SCHEDULER_QUEUE_ARN", queue.arn->Pulumi.Output.asInput)
  envVars->Dict.set(
    "SCHEDULER_QUEUE_NAME",
    queue.id->Pulumi.Output.apply(id =>
      id->String.split("/")->Array.at(-1)->Option.getOr(id)
    )->Pulumi.Output.asInput,
  )

  let publishToAggregatesEnvVars: dict<string> = Dict.make()
  info.publishToAggregatesQueueUrls->Dict.forEachWithKey((queueUrlOutput, aggName) => {
    let envVar = `PTA_${aggName}_QUEUE_URL`
    envVars->Dict.set(envVar, queueUrlOutput->Pulumi.Output.asInput)
    publishToAggregatesEnvVars->Dict.set(aggName, envVar)
  })

  let registration: Util_EntryPoint.bundledPluginExtensionPointRegistration = {
    queueUrlEnvVar: "EP_QUEUE_URL",
    queueArnEnvVar: "EP_QUEUE_ARN",
    publishToAggregatesEnvVars,
    pluginReadModelTableEnvVar: "PLUGIN_RM_TABLE",
    schedulerRoleArnEnvVar: "SCHEDULER_ROLE_ARN",
    schedulerQueueArnEnvVar: "SCHEDULER_QUEUE_ARN",
    schedulerQueueNameEnvVar: "SCHEDULER_QUEUE_NAME",
  }

  let entryPointCode = Util_EntryPoint.generateBundledPluginExtensionPointEntryPoint({
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
}
