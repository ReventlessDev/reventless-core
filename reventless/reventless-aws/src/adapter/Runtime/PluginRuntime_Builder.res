type adminConfig = {
  eventTopicArn: option<Pulumi.Output.t<string>>,
  pluginReadModelTableName: option<Pulumi.Output.t<string>>,
  schedulerRoleArn: option<Pulumi.Output.t<string>>,
  schedulerQueueArn: option<Pulumi.Output.t<string>>,
  schedulerQueueName: option<Pulumi.Output.t<string>>,
  appSyncApiId: option<Pulumi.Output.t<string>>,
  clonerEnabled: bool,
}

let configRef: ref<adminConfig> = ref({
  eventTopicArn: None,
  pluginReadModelTableName: None,
  schedulerRoleArn: None,
  schedulerQueueArn: None,
  schedulerQueueName: None,
  appSyncApiId: None,
  clonerEnabled: false,
})

type dcbConfig = {
  pluginName: string,
  dcbTableName: option<Pulumi.Output.t<string>>,
  stateChangeSliceSpecPaths: array<string>,
}

let dcbConfigRef: ref<dcbConfig> = ref({
  pluginName: "",
  dcbTableName: None,
  stateChangeSliceSpecPaths: [],
})

let registeredSliceSpecPaths: array<string> = []

let registerStateChangeSliceSpec = (specModulePath: string) => {
  let _ = registeredSliceSpecPaths->Array.push(specModulePath)
}

let registerDcbConfig = (~pluginName, ~dcbTableName=?, ~stateChangeSliceSpecPaths=[], ()) => {
  dcbConfigRef := {pluginName, dcbTableName, stateChangeSliceSpecPaths}
  stateChangeSliceSpecPaths->Array.length
}

type heartbeatConfig = {
  pluginId: string,
  heartbeatTimeout: int,
  epQueueUrl: option<Pulumi.Output.t<string>>,
}

let heartbeatConfigRef: ref<heartbeatConfig> = ref({
  pluginId: "",
  heartbeatTimeout: 10,
  epQueueUrl: None,
})

let registerHeartbeatConfig = (~pluginId, ~heartbeatTimeout=10, ~epQueueUrl=?, ()) =>
  heartbeatConfigRef := {pluginId, heartbeatTimeout, epQueueUrl}

let registerConfig = (
  ~eventTopicArn=?,
  ~pluginReadModelTableName=?,
  ~schedulerRoleArn=?,
  ~schedulerQueueArn=?,
  ~schedulerQueueName=?,
  ~appSyncApiId=?,
  ~clonerEnabled=false,
  (),
) =>
  configRef := {
    eventTopicArn,
    pluginReadModelTableName,
    schedulerRoleArn,
    schedulerQueueArn,
    schedulerQueueName,
    appSyncApiId,
    clonerEnabled,
  }

module Make = (
  EventCollectorChannel: ReventlessCore.EventCollector_Adapter.Channel
    with type runtimeParts = Util.Lambda.runtimeParts,
): (
  ReventlessCore.PluginRuntime_Builder.T
    with type context = PulumiAws.Lambda.context
    and type runtimeParts = Util.Lambda.runtimeParts
    and module EventCollectorChannel = EventCollectorChannel
) => {
  type context = PulumiAws.Lambda.context
  type runtimeParts = Util.Lambda.runtimeParts
  module EventCollectorChannel = EventCollectorChannel

  let outputOrPlaceholder = opt =>
    switch opt {
    | Some(v) => v->Pulumi.Output.asInput
    | None => "NOT_AVAILABLE"->Pulumi.Output.make->Pulumi.Output.asInput
    }

  let forPluginEventCollector: ReventlessCore.Runtime.forEventCollector<
    ReventlessCore.Runtime.effectHandler<
      EventCollectorChannel.callbackEvent,
      context,
      unit,
      string,
    >,
    ReventlessCore.EventCollector.component,
  > = (
    ~handler as _,
    ~eventTopics,
    ~resources,
    ~memorySize=1024,
    ~timeout=30,
    eventCollector,
  ) => {
    let resource = eventCollector->ReventlessCore.Component.toPulumiResource
    let name = resource.name->ReventlessCore.ComponentType.nameOpt(
      ReventlessCore.EventCollector.componentType,
    )
    let opts = {Pulumi.ComponentResource.parent: resource}
    let config = configRef.contents

    // Extract the SQS queue from the EventCollector channel
    let channel = eventCollector->ReventlessCore.EventCollector_Adapter.channel
    let channelParts: Util.SQS.channelParts = Obj.magic(channel.parts)
    let queue = channelParts.queue

    let envVars: dict<Pulumi.Input.t<string>> = Dict.make()

    // Build HANDLER_CONFIG JSON with all admin config values
    let handlerConfigJson =
      Pulumi.Output.all([
        queue.id,
        config.eventTopicArn->outputOrPlaceholder->Obj.magic,
        config.pluginReadModelTableName->outputOrPlaceholder->Obj.magic,
        config.schedulerRoleArn->outputOrPlaceholder->Obj.magic,
        config.schedulerQueueArn->outputOrPlaceholder->Obj.magic,
        config.schedulerQueueName->outputOrPlaceholder->Obj.magic,
        config.appSyncApiId->outputOrPlaceholder->Obj.magic,
      ])
      ->Pulumi.Output.apply(values => {
        let queueUrl = values->Array.getUnsafe(0)
        let eventTopicArn = values->Array.getUnsafe(1)
        let rmTable = values->Array.getUnsafe(2)
        let schedRoleArn = values->Array.getUnsafe(3)
        let schedQueueArn = values->Array.getUnsafe(4)
        let schedQueueName = values->Array.getUnsafe(5)
        let appSyncApiId = values->Array.getUnsafe(6)
        let clonerEnabled = config.clonerEnabled ? "true" : "false"
        `{"queueUrl":"${queueUrl}","eventTopicArn":"${eventTopicArn}","pluginReadModelTableName":"${rmTable}","schedulerRoleArn":"${schedRoleArn}","schedulerQueueArn":"${schedQueueArn}","schedulerQueueName":"${schedQueueName}","appSyncApiId":"${appSyncApiId}","clonerEnabled":${clonerEnabled}}`
      })
    envVars->Dict.set("HANDLER_CONFIG", handlerConfigJson->Pulumi.Output.asInput)

    // No user packages — all framework imports are in the Layer
    let reExportCode = `export { handler } from "@reventlessdev/reventless-aws/src/adapter/Runtime/AdminEventCollectorEntryPoint.mjs";`

    let archiveContents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
    archiveContents->Dict.set(
      "index.mjs",
      Pulumi.Asset.stringAsset(reExportCode)->Pulumi.Archive.assetToAssetOrArchive,
    )

    let code = Pulumi.Archive.assetArchive(archiveContents)
    let sourceCodeHash = Util_Bundle.hashString(reExportCode)

    let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
      ~name,
      ~code,
      ~sourceCodeHash,
      ~envVars,
      ~memorySize,
      ~timeout,
      ~opts,
    )
    let _connectResources = EventCollectorChannel.connect(
      ~name,
      ~channelSpecs=[
        {
          channel: eventCollector->ReventlessCore.EventCollector_Adapter.channel,
          eventTopics,
          resources,
        },
      ],
      ~runtime,
      ~opts,
    )
  }

  let forPluginHeartbeat: ReventlessCore.Runtime.forComponent<
    ReventlessCore.Runtime.eventHandler<unit, context, unit>,
    runtimeParts,
    ReventlessCore.Heartbeat.component,
  > = (
    ~handler as _,
    ~connect,
    ~memorySize=1024,
    ~timeout=30,
    heartbeat,
  ) => {
    let hbConfig = heartbeatConfigRef.contents
    switch hbConfig.epQueueUrl {
    | None =>
      Console.warn("PluginRuntime_Builder: forPluginHeartbeat skipped (no EP queue URL)")
    | Some(epQueueUrl) =>
      let resource = heartbeat->ReventlessCore.Component.toPulumiResource
      let name = resource.name->ReventlessCore.ComponentType.nameOpt(
        ReventlessCore.Heartbeat.componentType,
      )
      let opts = {Pulumi.ComponentResource.parent: resource}

      let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
      envVars->Dict.set("EP_QUEUE_URL", epQueueUrl->Pulumi.Output.asInput)
      envVars->Dict.set(
        "PLUGIN_ID",
        hbConfig.pluginId->Pulumi.Output.make->Pulumi.Output.asInput,
      )
      envVars->Dict.set(
        "HEARTBEAT_TIMEOUT",
        hbConfig.heartbeatTimeout->Int.toString->Pulumi.Output.make->Pulumi.Output.asInput,
      )

      // Static re-export from Layer entry point — no esbuild, no user packages
      let reExportCode = `export { handler } from "@reventlessdev/reventless-aws/src/adapter/Runtime/HeartbeatEntryPoint.mjs";`
      let archiveContents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
      archiveContents->Dict.set(
        "index.mjs",
        Pulumi.Asset.stringAsset(reExportCode)->Pulumi.Archive.assetToAssetOrArchive,
      )
      let code = Pulumi.Archive.assetArchive(archiveContents)
      let sourceCodeHash = Util_Bundle.hashString(reExportCode)

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
    }
  }

  let forDcbCommandTopic: ReventlessCore.Runtime.forComponent<
    ReventlessCore.Runtime.effectHandler<'callbackEvent, context, unit, string>,
    runtimeParts,
    ReventlessCore.CommandTopic.component<'op>,
  > = (
    ~handler as _,
    ~connect,
    ~memorySize=1024,
    ~timeout=30,
    dcbCommandTopic,
  ) => {
    let dcbConfig = dcbConfigRef.contents
    // Merge spec paths: auto-registered (from moduleUrl) + manually registered (from registerDcbConfig)
    let allSpecPaths = registeredSliceSpecPaths->Array.concat(dcbConfig.stateChangeSliceSpecPaths)
    if allSpecPaths->Array.length == 0 {
      Console.warn("PluginRuntime_Builder: forDcbCommandTopic skipped (no slice specs)")
    } else {
      let commandTopicResource = dcbCommandTopic->ReventlessCore.Component.toPulumiResource
      let name = commandTopicResource.name->ReventlessCore.ComponentType.nameOpt(
        ReventlessCore.CommandTopic.componentType,
      )
      let opts = {Pulumi.ComponentResource.parent: commandTopicResource}

      // Extract SQS queue from the DCB CommandTopic
      let channel = dcbCommandTopic->ReventlessCore.CommandTopic_Adapter.channel
      let channelParts: Util.SQS.channelParts = Obj.magic(channel.parts)
      let queue = channelParts.queue

      // Get DCB EventLog table name from the DcbEventLog resources (passed via dcbConfig)
      let dcbTableName = switch dcbConfig.dcbTableName {
      | Some(tableName) => tableName
      | None => Pulumi.Output.make("NOT_AVAILABLE")
      }

      let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
      envVars->Dict.set("DCB_TABLE", dcbTableName->Pulumi.Output.asInput)
      envVars->Dict.set("QUEUE_URL", queue.id->Pulumi.Output.asInput)

      // Build HANDLER_CONFIG JSON with all slice spec module paths
      let sliceSpecsJson =
        allSpecPaths
        ->Array.map(p => p->JSON.stringifyAny->Option.getOr(`""`))
        ->Array.join(",")

      let handlerConfigJson =
        Pulumi.Output.all2((dcbTableName, queue.id))
        ->Pulumi.Output.apply(((table, queueUrl)) => {
          let pluginName =
            dcbConfig.pluginName->JSON.stringifyAny->Option.getOr(`""`)
          `{"dcbEventLogTableName":"${table}","queueUrl":"${queueUrl}","pluginName":${pluginName},"stateChangeSliceModules":[${sliceSpecsJson}]}`
        })
      envVars->Dict.set("HANDLER_CONFIG", handlerConfigJson->Pulumi.Output.asInput)

      // Build code asset
      let packageDirs: dict<string> = Dict.make()
      allSpecPaths->Array.forEach(specPath => {
        let pkg = Util_Bundle.extractPackageName(specPath)
        packageDirs->Dict.set(pkg, Util_Bundle.resolvePackageRoot(pkg))
      })
      // Include reventless-aws itself so hand-written entry point (.mjs) files
      // in the zip take precedence over the Lambda layer, ensuring the latest
      // local version is used.
      packageDirs->Dict.set(
        "@reventlessdev/reventless-aws",
        Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-aws"),
      )

      let reExportCode = `export { handler } from "@reventlessdev/reventless-aws/src/adapter/Runtime/DcbCommandTopicEntryPoint.mjs";`

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
        ~name,
        ~code,
        ~sourceCodeHash,
        ~envVars,
        ~memorySize,
        ~timeout,
        ~opts,
      )

      // The DCB command topic Lambda is invoked directly by AppSync (Route 1) and
      // needs sqs:SendMessage to publish commands to the FIFO queue for processing.
      // makeWithDefaultPolicy only grants sqs:Receive* (for SQS trigger Route 2).
      let _ = queue.arn->Pulumi.Output.apply(queueArn => {
        PulumiAws.IAM.RolePolicy.make(
          ~name=`${name}-sqsSend`,
          ~args={
            policy: PulumiAws.PolicyDocument.make(
              ~id=`${name}-sqsSendPolicy`,
              ~statements=[
                {
                  sid: "AllowSqsSend",
                  effect: Allow,
                  actions: Action("sqs:SendMessage"),
                  resources: Resource(queueArn),
                },
              ],
            )
            ->PulumiAws.PolicyDocument.toJsonString
            ->Pulumi.Input.make,
            role: runtime.parts.lambdaRole.id->Pulumi.Output.asInput,
          },
        )
      })

      connect(~runtime)
    }
  }

  let finish = () => ()
}
