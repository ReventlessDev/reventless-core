type bundledAdminConfig = {
  eventTopicArn: option<Pulumi.Output.t<string>>,
  pluginReadModelTableName: option<Pulumi.Output.t<string>>,
  schedulerRoleArn: option<Pulumi.Output.t<string>>,
  schedulerQueueArn: option<Pulumi.Output.t<string>>,
  schedulerQueueName: option<Pulumi.Output.t<string>>,
  appSyncApiId: option<Pulumi.Output.t<string>>,
  clonerEnabled: bool,
}

let configRef: ref<bundledAdminConfig> = ref({
  eventTopicArn: None,
  pluginReadModelTableName: None,
  schedulerRoleArn: None,
  schedulerQueueArn: None,
  schedulerQueueName: None,
  appSyncApiId: None,
  clonerEnabled: false,
})

type bundledDcbConfig = {
  pluginName: string,
  dcbTableName: option<Pulumi.Output.t<string>>,
  stateChangeSliceSpecPaths: array<string>,
}

let dcbConfigRef: ref<bundledDcbConfig> = ref({
  pluginName: "",
  dcbTableName: None,
  stateChangeSliceSpecPaths: [],
})

let registerDcbConfig = (~pluginName, ~dcbTableName=?, ~stateChangeSliceSpecPaths=[], ()) => {
  dcbConfigRef := {pluginName, dcbTableName, stateChangeSliceSpecPaths}
  stateChangeSliceSpecPaths->Array.length
}

type bundledHeartbeatConfig = {
  pluginId: string,
  heartbeatTimeout: int,
  epQueueUrl: option<Pulumi.Output.t<string>>,
}

let heartbeatConfigRef: ref<bundledHeartbeatConfig> = ref({
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

    let factoryModulePath =
      "@reventlessdev/reventless-aws/src/adapter/Runtime/AdminEventCollectorHandlerFactory.mjs"
    let requestContextModulePath =
      "@reventlessdev/reventless-core/src/RequestContext.res.mjs"

    let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
    envVars->Dict.set("EC_QUEUE_URL", queue.id->Pulumi.Output.asInput)
    envVars->Dict.set("EP_EVENT_TOPIC_ARN", config.eventTopicArn->outputOrPlaceholder)
    envVars->Dict.set("PLUGIN_RM_TABLE", config.pluginReadModelTableName->outputOrPlaceholder)
    envVars->Dict.set("SCHEDULER_ROLE_ARN", config.schedulerRoleArn->outputOrPlaceholder)
    envVars->Dict.set(
      "SCHEDULER_QUEUE_ARN",
      config.schedulerQueueArn->outputOrPlaceholder,
    )
    envVars->Dict.set(
      "SCHEDULER_QUEUE_NAME",
      config.schedulerQueueName->outputOrPlaceholder,
    )
    envVars->Dict.set("APPSYNC_API_ID", config.appSyncApiId->outputOrPlaceholder)
    envVars->Dict.set(
      "CLONER_ENABLED",
      (config.clonerEnabled ? "true" : "false")->Pulumi.Output.make->Pulumi.Output.asInput,
    )

    let entryPointCode = Util_EntryPoint.generateAdminEventCollectorEntryPoint({
      name,
      factoryModule: factoryModulePath,
      requestContextModule: requestContextModulePath,
      queueUrlEnvVar: "EC_QUEUE_URL",
      eventTopicArnEnvVar: "EP_EVENT_TOPIC_ARN",
      pluginReadModelTableEnvVar: "PLUGIN_RM_TABLE",
      schedulerRoleArnEnvVar: "SCHEDULER_ROLE_ARN",
      schedulerQueueArnEnvVar: "SCHEDULER_QUEUE_ARN",
      schedulerQueueNameEnvVar: "SCHEDULER_QUEUE_NAME",
      appSyncApiIdEnvVar: "APPSYNC_API_ID",
      clonerEnabledEnvVar: "CLONER_ENABLED",
    })

    let runtime = RuntimeEnvironment_Lambda.makeBundledFromEntryPoint(
      ~name,
      ~entryPointCode,
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

      let factoryModulePath =
        "@reventlessdev/reventless-aws/src/adapter/Runtime/HeartbeatHandlerFactory.mjs"

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

      let entryPointCode = Util_EntryPoint.generateHeartbeatEntryPoint({
        name,
        factoryModule: factoryModulePath,
        epQueueUrlEnvVar: "EP_QUEUE_URL",
        pluginIdEnvVar: "PLUGIN_ID",
        timeoutEnvVar: "HEARTBEAT_TIMEOUT",
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
    if dcbConfig.stateChangeSliceSpecPaths->Array.length == 0 {
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

      let factoryModulePath =
        "@reventlessdev/reventless-aws/src/adapter/Runtime/DcbCommandTopicHandlerFactory.mjs"
      let requestContextModulePath =
        "@reventlessdev/reventless-core/src/RequestContext.res.mjs"

      // Get DCB EventLog table name from the DcbEventLog resources (passed via dcbConfig)
      let dcbTableName = switch dcbConfig.dcbTableName {
      | Some(tableName) => tableName
      | None => Pulumi.Output.make("NOT_AVAILABLE")
      }

      let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
      envVars->Dict.set("DCB_TABLE", dcbTableName->Pulumi.Output.asInput)
      envVars->Dict.set("QUEUE_URL", queue.id->Pulumi.Output.asInput)

      let stateChangeSliceSpecs: array<Util_EntryPoint.dcbSliceSpec> =
        dcbConfig.stateChangeSliceSpecPaths->Array.map(specModulePath => {
          Util_EntryPoint.specModulePath: specModulePath,
        })

      let entryPointCode = Util_EntryPoint.generateDcbCommandTopicEntryPoint({
        name,
        factoryModule: factoryModulePath,
        requestContextModule: requestContextModulePath,
        dcbTableEnvVar: "DCB_TABLE",
        queueUrlEnvVar: "QUEUE_URL",
        pluginName: dcbConfig.pluginName,
        stateChangeSliceSpecs,
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
  }

  let finish = () => ()
}
