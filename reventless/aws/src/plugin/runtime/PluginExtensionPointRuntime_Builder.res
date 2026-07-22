module CommandTopicChannel = CommandTopicChannel.SQS_Sync
module RuntimeEnvironment = RuntimeEnvironment.Lambda

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

// Admin-specific data that the Plugin extension point Lambda needs but that
// the generic ExtensionPointRuntime_Builder.T params don't carry. Wired in
// from `Platform.res` after `Admin.construct()` exposes the read model and
// scheduler resources; consumed lazily at deploy-resolve time when
// `forCommandTopic` runs inside its `Pulumi.Output.apply`.
type adminExtras = {
  pluginReadModelTableName: option<Pulumi.Output.t<string>>,
  schedulerRoleArn: option<Pulumi.Output.t<string>>,
}

let adminExtras: ref<adminExtras> = ref({
  pluginReadModelTableName: None,
  schedulerRoleArn: None,
})

let registerPluginExtensionPoint = (~pluginReadModelTableName=?, ~schedulerRoleArn=?, ()) =>
  adminExtras := {pluginReadModelTableName, schedulerRoleArn}

let forCommandTopic = (
  ~handler as _,
  ~connect,
  ~memorySize=1024,
  ~timeout=30,
  ~specModulePath as _,
  ~mappingsModulePath as _,
  ~publishToAggregatesQueueUrls,
  commandTopic,
) => {
  let commandTopicResource = commandTopic->ReventlessCore.Component.toPulumiResource
  let extras = adminExtras.contents

  let channel = commandTopic->ReventlessCore.CommandTopic_Adapter.channel
  let channelParts: Util.SQS.channelParts = Obj.magic(channel.parts)
  let queue = channelParts.queue

  // The EP command-handler Lambda inherits the bare EP CommandTopic resource
  // name (`<EP>ExtPoint`) and appends the unified `CmdHandler` kind so it is
  // greppable alongside the aggregate/DCB command handlers (analysis §8.2).
  // Mirrors ExtensionPointRuntime_Builder_PerExtensionPoint.
  let name = commandTopicResource.name->Option.getOr("UnnamedExtPoint") ++ "CmdHandler"
  let opts = {Pulumi.ComponentResource.parent: commandTopicResource}

  let envVars: dict<Pulumi.Input.t<string>> = Dict.make()

  let outputOrPlaceholder = opt =>
    switch opt {
    | Some(v) => v->Pulumi.Output.asInput
    | None => "NOT_AVAILABLE"->Pulumi.Output.make->Pulumi.Output.asInput
    }

  // Build publishToAggregates env var mapping
  let publishToAggregatesEnvVars: dict<string> = Dict.make()
  publishToAggregatesQueueUrls->Dict.forEachWithKey((queueUrlOutput, aggName) => {
    let envVar = `PTA_${aggName}_QUEUE_URL`
    envVars->Dict.set(envVar, queueUrlOutput->Pulumi.Output.asInput)
    publishToAggregatesEnvVars->Dict.set(aggName, envVar)
  })

  let publishToAggregatesJson =
    publishToAggregatesEnvVars
    ->Dict.toArray
    ->Array.map(((aggName, envVar)) =>
      `${aggName->JSON.stringifyAny->Option.getOr(`""`)}: ${envVar->JSON.stringifyAny->Option.getOr(`""`)}`
    )
    ->Array.join(",")

  // Build HANDLER_CONFIG JSON
  let queueName =
    queue.id->Pulumi.Output.apply(id =>
      id->String.split("/")->Array.at(-1)->Option.getOr(id)
    )

  let handlerConfigJson =
    Pulumi.Output.all([
      queue.id,
      extras.pluginReadModelTableName->outputOrPlaceholder->Obj.magic,
      extras.schedulerRoleArn->outputOrPlaceholder->Obj.magic,
      queue.arn,
      queueName,
    ])
    ->Pulumi.Output.apply(values => {
      let queueUrl = values->Array.getUnsafe(0)
      let rmTable = values->Array.getUnsafe(1)
      let schedRoleArn = values->Array.getUnsafe(2)
      let schedQueueArn = values->Array.getUnsafe(3)
      let schedQueueName = values->Array.getUnsafe(4)
      `{"queueUrl":"${queueUrl}","pluginReadModelTableName":"${rmTable}","schedulerRoleArn":"${schedRoleArn}","schedulerQueueArn":"${schedQueueArn}","schedulerQueueName":"${schedQueueName}","publishToAggregates":{${publishToAggregatesJson}}}`
    })
  envVars->Dict.set("HANDLER_CONFIG", handlerConfigJson->Pulumi.Output.asInput)

  // No user packages — all framework imports are in the Layer
  let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
    ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/PluginExtensionPointEntryPoint.mjs",
    ~packageDirs=Dict.make(),
  )

  let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
    ~name,
    ~unitKind=ReventlessCore.Monitoring.CommandHandler,
    ~componentKind=ReventlessCore.ComponentType.ExtensionPoint,
    ~code,
    ~sourceCodeHash,
    ~envVars,
    ~memorySize,
    ~timeout,
    ~opts,
  )
  connect(~runtime)
}

let finish = () => ()
