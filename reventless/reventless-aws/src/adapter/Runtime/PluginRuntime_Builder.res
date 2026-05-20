type adminConfig = {
  eventTopicArn: option<Pulumi.Output.t<string>>,
  pluginReadModelTableName: option<Pulumi.Output.t<string>>,
  // Dedicated PluginSchemaPersistence table holding deploy-time SDL fragments
  // (rows keyed "deploy-schema:<name>"). The runtime schema stitch reads this
  // durable source instead of the lifecycle-volatile Plugin RM Connected rows.
  pluginSchemaPersistenceTableName: option<Pulumi.Output.t<string>>,
  schedulerRoleArn: option<Pulumi.Output.t<string>>,
  schedulerQueueArn: option<Pulumi.Output.t<string>>,
  schedulerQueueName: option<Pulumi.Output.t<string>>,
  appSyncApiId: option<Pulumi.Output.t<string>>,
  clonerEnabled: bool,
}

let configRef: ref<adminConfig> = ref({
  eventTopicArn: None,
  pluginReadModelTableName: None,
  pluginSchemaPersistenceTableName: None,
  schedulerRoleArn: None,
  schedulerQueueArn: None,
  schedulerQueueName: None,
  appSyncApiId: None,
  clonerEnabled: false,
})

type sliceModulePaths = {
  specPath: string,
  behaviorPath: string,
}

type dcbConfig = {
  pluginName: string,
  dcbTableName: option<Pulumi.Output.t<string>>,
  stateChangeSliceModulePaths: array<sliceModulePaths>,
}

let dcbConfigRef: ref<dcbConfig> = ref({
  pluginName: "",
  dcbTableName: None,
  stateChangeSliceModulePaths: [],
})

let registeredSliceModulePaths: array<sliceModulePaths> = []

let registerStateChangeSliceSpec = (~specPath: string, ~behaviorPath: string) => {
  let _ = registeredSliceModulePaths->Array.push({specPath, behaviorPath})
}

let registerDcbConfig = (~pluginName, ~dcbTableName=?, ~stateChangeSliceModulePaths=[], ()) => {
  dcbConfigRef := {pluginName, dcbTableName, stateChangeSliceModulePaths}
  stateChangeSliceModulePaths->Array.length
}

let registerDcbTableName = (dcbTableName: Pulumi.Output.t<string>) =>
  dcbConfigRef := {...dcbConfigRef.contents, dcbTableName: Some(dcbTableName)}

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

// Per-flavor commandHandlerConfig override for the two `<Plugin>StateChanges` Lambdas;
// populated by Platform.MakeWithConfig from `commandHandlerConfig.stateChanges.{sync,async}`.
let syncStateChangesConfigRef: ref<ReventlessCore.Runtime.commandHandlerConfig> = ref(
  ({}: ReventlessCore.Runtime.commandHandlerConfig),
)
let asyncStateChangesConfigRef: ref<ReventlessCore.Runtime.commandHandlerConfig> = ref(
  ({}: ReventlessCore.Runtime.commandHandlerConfig),
)
let setStateChangesConfig = (~sync=?, ~async=?, ()) => {
  sync->Option.forEach(c => syncStateChangesConfigRef := c)
  async->Option.forEach(c => asyncStateChangesConfigRef := c)
}

let registerConfig = (
  ~eventTopicArn=?,
  ~pluginReadModelTableName=?,
  ~pluginSchemaPersistenceTableName=?,
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
    pluginSchemaPersistenceTableName,
    schedulerRoleArn,
    schedulerQueueArn,
    schedulerQueueName,
    appSyncApiId,
    clonerEnabled,
  }

// PluginRuntime_Builder is a functor so that the caller can inject the EventCollectorChannel
// implementation. All other runtime builders hardcode EventCollectorChannel.DynamoDbStream, but
// the Plugin admin handler (AdminEventCollectorEntryPoint) is shared across DCB and aggregate
// plugins which may use different event log backends. The functor keeps the builder generic
// while the concrete instantiation picks the right channel at the platform level.
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

  let registerPluginName = (pluginName: string) =>
    dcbConfigRef := {...dcbConfigRef.contents, pluginName}

  let outputOrPlaceholder = opt =>
    switch opt {
    | Some(v) => v->Pulumi.Output.asInput
    | None => "NOT_AVAILABLE"->Pulumi.Output.make->Pulumi.Output.asInput
    }

  // Synthesises an admin-flavoured eventCollectorContext when no plugin context
  // is registered for this EventCollector. The admin Lambda processes outgoing
  // events of its own Plugin ExtensionPoint and does not consume the auto-
  // included Connect extension (it IS the Plugin EP). The fake pluginDefinition
  // keeps the JSON shape consistent so the entry point can parse uniformly.
  let synthesizeAdminContext = (): ReventlessCore.Plugin_Helpers.eventCollectorContext => {
    let config = configRef.contents
    // Stable JSON literal — matches Reventless.Plugin.pluginDefinitionSchema
    // (optional fields encoded as null via js_nullable).
    let fakePluginDefinitionJson =
      `{"id":"Admin@INTERNAL","name":"Admin","version":"INTERNAL","extensionPoints":[],"extensions":[],"eventCollector":"NOT-SET","extensionProtocols":[],"apiSchemaFragment":null,"apiTarget":null,"uiFragments":null,"structure":null}`->Pulumi.Output.make
    let adminEpEventTopicArn = switch config.eventTopicArn {
    | Some(arn) => arn
    | None => Pulumi.Output.make("NOT_AVAILABLE")
    }
    {
      pluginDefinitionJson: fakePluginDefinitionJson,
      extensionPoints: [
        {
          specModule: ReventlessCore.Plugin_Helpers.adminPluginExtensionPointSpecModule,
          mappingsModule: ReventlessCore.Plugin_Helpers.adminPluginExtensionPointMappingsModule,
          eventTopicArn: adminEpEventTopicArn,
          aggregateNames: [ReventlessCore.PluginSpec.name],
        },
      ],
      connectExtension: None,
      extensions: [],
      pluginExtensionPointCmdTopicUrl: Pulumi.Output.make(""),
      publishToAggregates: Dict.make(),
      readModelQueueUrls: Dict.make(),
      readModelNamesForSourceName: Dict.make(),
    }
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

    // Pull the per-EventCollector context registered by Plugin_Helpers.connect
    // (plugins) or synthesise an admin one if none registered.
    let context: ReventlessCore.Plugin_Helpers.eventCollectorContext =
      switch ReventlessCore.Plugin_Helpers.eventCollectorContextRef.contents->Dict.get(name) {
      | Some(ctx) => ctx
      | None => synthesizeAdminContext()
      }

    let envVars: dict<Pulumi.Input.t<string>> = Dict.make()

    // Lambda env vars carry the actual cmd-topic URLs that publishToAggregates
    // points at (HANDLER_CONFIG holds only the env-var names — same indirection
    // PluginExtensionPointEntryPoint uses).
    context.publishToAggregates
    ->Dict.toArray
    ->Array.forEach(((_aggName, queueUrlOutput)) => {
      // Env var name follows the existing convention: PTA_<aggregate>_QUEUE_URL.
      let envVarName = `PTA_${_aggName}_QUEUE_URL`
      envVars->Dict.set(envVarName, queueUrlOutput->Pulumi.Output.asInput)
    })

    // Same indirection for ReadModel EventCollector SQS URLs — only populated
    // when user extensions enqueue directly into RMs (Extension_Operations
    // publishToReadModels path). Empty for the admin Lambda and for the
    // current Orders_Extension fixture (its RM is fed via the slice EventLog →
    // RM EventColl subscription chain instead).
    context.readModelQueueUrls
    ->Dict.toArray
    ->Array.forEach(((_rmName, queueUrlOutput)) => {
      let envVarName = `PRM_${_rmName}_QUEUE_URL`
      envVars->Dict.set(envVarName, queueUrlOutput->Pulumi.Output.asInput)
    })

    // Outgoing arrays first — resolve EP eventTopicArns, then bundle everything
    // into one Output.apply that builds the JSON.
    let epEventTopicArnsOutput =
      context.extensionPoints
      ->Array.map(ep => ep.eventTopicArn)
      ->Pulumi.Output.all

    // HANDLER_CONFIG no longer carries pluginDefinition — it grew past AWS
    // Lambda's 5120-byte UpdateFunctionConfiguration limit once pluginStructure
    // started landing inline. The full pluginDefinition is shipped as a
    // separate `pluginDefinition.json` asset bundled alongside index.mjs (see
    // the buildCodeArchive call below); the entry point reads it from disk at
    // cold start. Slim HANDLER_CONFIG keeps just the orchestration fields.
    let handlerConfigJson =
      Pulumi.Output.all([
        queue.id,
        context.pluginExtensionPointCmdTopicUrl->Pulumi.Output.asInput->Obj.magic,
        config.eventTopicArn->outputOrPlaceholder->Obj.magic,
        config.pluginReadModelTableName->outputOrPlaceholder->Obj.magic,
        config.schedulerRoleArn->outputOrPlaceholder->Obj.magic,
        config.schedulerQueueArn->outputOrPlaceholder->Obj.magic,
        config.schedulerQueueName->outputOrPlaceholder->Obj.magic,
        config.appSyncApiId->outputOrPlaceholder->Obj.magic,
        epEventTopicArnsOutput->Pulumi.Output.asInput->Obj.magic,
        config.pluginSchemaPersistenceTableName->outputOrPlaceholder->Obj.magic,
      ])
      ->Pulumi.Output.apply(values => {
        let queueUrl = values->Array.getUnsafe(0)
        let pluginEpCmdTopicUrl = values->Array.getUnsafe(1)
        let topLevelEventTopicArn = values->Array.getUnsafe(2)
        let rmTable = values->Array.getUnsafe(3)
        let schedRoleArn = values->Array.getUnsafe(4)
        let schedQueueArn = values->Array.getUnsafe(5)
        let schedQueueName = values->Array.getUnsafe(6)
        let appSyncApiId = values->Array.getUnsafe(7)
        let epEventTopicArns: array<string> = Obj.magic(values->Array.getUnsafe(8))
        let schemaPersistenceTable = values->Array.getUnsafe(9)

        let dict = Dict.make()
        dict->Dict.set("queueUrl", JSON.Encode.string(queueUrl))
        dict->Dict.set("pluginExtensionPointCmdTopicUrl", JSON.Encode.string(pluginEpCmdTopicUrl))
        dict->Dict.set("eventTopicArn", JSON.Encode.string(topLevelEventTopicArn))
        dict->Dict.set("pluginReadModelTableName", JSON.Encode.string(rmTable))
        dict->Dict.set(
          "pluginSchemaPersistenceTableName",
          JSON.Encode.string(schemaPersistenceTable),
        )
        dict->Dict.set("appSyncApiId", JSON.Encode.string(appSyncApiId))
        dict->Dict.set("clonerEnabled", JSON.Encode.bool(config.clonerEnabled))
        dict->Dict.set("schedulerRoleArn", JSON.Encode.string(schedRoleArn))
        dict->Dict.set("schedulerQueueArn", JSON.Encode.string(schedQueueArn))
        dict->Dict.set("schedulerQueueName", JSON.Encode.string(schedQueueName))

        // pluginDefinition lives in pluginDefinition.json (see asset bundle
        // below). The entry point reads it via fs.readFileSync at cold start.

        let extensionPointsArr = context.extensionPoints->Array.mapWithIndex((ep, i) => {
          let entryDict = Dict.make()
          entryDict->Dict.set("specModule", JSON.Encode.string(ep.specModule))
          entryDict->Dict.set("mappingsModule", JSON.Encode.string(ep.mappingsModule))
          entryDict->Dict.set("eventTopicArn", JSON.Encode.string(epEventTopicArns->Array.getUnsafe(i)))
          entryDict->Dict.set(
            "aggregateNames",
            ep.aggregateNames->Array.map(JSON.Encode.string)->JSON.Encode.array,
          )
          JSON.Encode.object(entryDict)
        })
        dict->Dict.set("extensionPoints", JSON.Encode.array(extensionPointsArr))

        let connectExtensionValue = switch context.connectExtension {
        | Some(ce) =>
          let ceDict = Dict.make()
          ceDict->Dict.set("specModule", JSON.Encode.string(ce.specModule))
          ceDict->Dict.set("mappingsModule", JSON.Encode.string(ce.mappingsModule))
          ceDict->Dict.set("extensionPointName", JSON.Encode.string(ce.extensionPointName))
          JSON.Encode.object(ceDict)
        | None => JSON.Encode.null
        }
        dict->Dict.set("connectExtension", connectExtensionValue)

        // User-declared extensions — one entry per merged extension group.
        // Each entry carries enough metadata for the bundled handler to
        // dynamic-import the spec / mapping modules and filter the top-level
        // publishToAggregates + readModelQueueUrls maps down to the subset
        // this extension actually uses.
        let extensionsArr = context.extensions->Array.map(ext => {
          let entryDict = Dict.make()
          entryDict->Dict.set("name", JSON.Encode.string(ext.name))
          entryDict->Dict.set("specModule", JSON.Encode.string(ext.specModule))
          entryDict->Dict.set("mappingsModule", JSON.Encode.string(ext.mappingsModule))
          entryDict->Dict.set("delegateModule", JSON.Encode.string(ext.delegateModule))
          entryDict->Dict.set("extensionPointName", JSON.Encode.string(ext.extensionPointName))
          entryDict->Dict.set(
            "aggregateNames",
            ext.aggregateNames->Array.map(JSON.Encode.string)->JSON.Encode.array,
          )
          entryDict->Dict.set(
            "readModelNames",
            ext.readModelNames->Array.map(JSON.Encode.string)->JSON.Encode.array,
          )
          JSON.Encode.object(entryDict)
        })
        dict->Dict.set("extensions", JSON.Encode.array(extensionsArr))

        let publishToAggregatesDict = Dict.make()
        context.publishToAggregates
        ->Dict.keysToArray
        ->Array.forEach(aggName =>
          publishToAggregatesDict->Dict.set(
            aggName,
            JSON.Encode.string(`PTA_${aggName}_QUEUE_URL`),
          )
        )
        dict->Dict.set("publishToAggregates", JSON.Encode.object(publishToAggregatesDict))

        let readModelQueueUrlsDict = Dict.make()
        context.readModelQueueUrls
        ->Dict.keysToArray
        ->Array.forEach(rmName =>
          readModelQueueUrlsDict->Dict.set(
            rmName,
            JSON.Encode.string(`PRM_${rmName}_QUEUE_URL`),
          )
        )
        dict->Dict.set("readModelQueueUrls", JSON.Encode.object(readModelQueueUrlsDict))

        let rmNamesForSourceDict = Dict.make()
        context.readModelNamesForSourceName
        ->Dict.toArray
        ->Array.forEach(((sourceName, rmNames)) =>
          rmNamesForSourceDict->Dict.set(
            sourceName,
            rmNames->Array.map(JSON.Encode.string)->JSON.Encode.array,
          )
        )
        dict->Dict.set("readModelNamesForSourceName", JSON.Encode.object(rmNamesForSourceDict))

        JSON.Encode.object(dict)->JSON.stringify
      })
    envVars->Dict.set("HANDLER_CONFIG", handlerConfigJson->Pulumi.Output.asInput)

    // User-extension packages: each merged extension entry contributes three
    // module specifiers (EP spec, user mapping file, delegate spec). Extract
    // their npm package names and resolve to package roots so buildCodeArchive
    // can include them in the asset zip — the bundled entry point then
    // dynamic-imports each module at cold start. Admin path has no
    // extensions, so packageDirs stays empty and the asset matches the
    // pre-extension-wiring shape.
    let packageDirs: dict<string> = Dict.make()
    context.extensions->Array.forEach(ext => {
      [ext.specModule, ext.mappingsModule, ext.delegateModule]
      ->Array.forEach(spec => {
        let pkgName = Util_Bundle.extractPackageName(spec)
        packageDirs->Dict.set(pkgName, Util_Bundle.resolvePackageRoot(pkgName))
      })
    })
    // Bundle the framework packages alongside the entry point so the deployed
    // Lambda picks up uncommitted local changes without waiting for the Lambda
    // Layer rebuild (the layer fetches @reventlessdev/reventless-* from GitHub
    // Packages, not the local pnpm workspace). Mirrors the DCB asset pattern in
    // forDcbCommandTopic below. Slightly larger function bundle in exchange
    // for matching dev/CI source.
    packageDirs->Dict.set(
      "@reventlessdev/reventless-aws",
      Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-aws"),
    )
    packageDirs->Dict.set(
      "@reventlessdev/reventless-core",
      Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-core"),
    )

    // pluginDefinition.json must resolve before the asset zip is built;
    // wrap the bundle in an Output.apply over the Output<string>. The
    // resulting Output<codeArchive> threads through to makeFromCodeAsset's
    // Archive.t / string args via Obj.magic — Pulumi's TS API accepts
    // Output<Archive.t> wherever it accepts Archive.t, and Pulumi.Input.make
    // is identity at runtime, so the Output unwraps correctly inside the
    // Lambda Function args.
    let bundleOutput =
      context.pluginDefinitionJson->Pulumi.Output.apply(pluginDefinitionJson => {
        let extraStringAssets = Dict.make()
        extraStringAssets->Dict.set("pluginDefinition.json", pluginDefinitionJson)
        Util_Bundle.buildCodeArchive(
          ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/AdminEventCollectorEntryPoint.mjs",
          ~packageDirs,
          ~extraStringAssets,
        )
      })
    let codeOutput = bundleOutput->Pulumi.Output.apply(b => b.code)
    let sourceCodeHashOutput = bundleOutput->Pulumi.Output.apply(b => b.sourceCodeHash)

    let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
      ~name,
      ~code=codeOutput->Obj.magic,
      ~sourceCodeHash=sourceCodeHashOutput->Obj.magic,
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

    // Admin-only cross-plugin SNS subscription permissions. The admin EC
    // Lambda's manageSubscriptions hook (Phase 3 Step 1) creates SNS
    // subscriptions at runtime as plugins connect/disconnect; that needs
    // sns:Subscribe / sns:Unsubscribe / sns:ListSubscriptionsByTopic on every
    // plugin's EP event topic. Detected via the same context lookup used to
    // synthesize the admin-flavoured handler config: no registered context
    // for this EventCollector name => admin path. Per-plugin EC Lambdas have
    // a registered context and stay on the narrow IAM perimeter from
    // EventCollectorChannel_Helpers.connectLambda.
    let isAdminEventCollector =
      ReventlessCore.Plugin_Helpers.eventCollectorContextRef.contents
      ->Dict.get(name)
      ->Option.isNone
    if isAdminEventCollector {
      let _ = PulumiAws.IAM.RolePolicy.make(
        ~name=`${name}-snsManageSubs`,
        ~args={
          policy: PulumiAws.PolicyDocument.make(
            ~id=`${name}SnsManageSubsPolicy`,
            ~statements=[
              {
                sid: "AllowAdminManageCrossPluginSnsSubscriptions",
                effect: Allow,
                actions: Actions([
                  "sns:Subscribe",
                  "sns:Unsubscribe",
                  "sns:ListSubscriptionsByTopic",
                  "sns:GetSubscriptionAttributes",
                ]),
                resources: AllResources,
              },
              // mkUpdateApiSchema runs on each Connect/Disconnect alongside
              // manageSubscriptions — pushes the stitched SDL to AppSync via
              // StartSchemaCreation. AppSync requires both the API-level
              // appsync:StartSchemaCreation and appsync:GetSchemaCreationStatus
              // permissions on the deployed API. GetIntrospectionSchema backs the
              // shrink-guard circuit breaker, which reads the live schema before
              // pushing to detect (and refuse) a catastrophic field-count drop.
              {
                sid: "AllowAdminStartSchemaCreation",
                effect: Allow,
                actions: Actions([
                  "appsync:StartSchemaCreation",
                  "appsync:GetSchemaCreationStatus",
                  "appsync:GetIntrospectionSchema",
                ]),
                resources: AllResources,
              },
            ],
          )
          ->PulumiAws.PolicyDocument.toJsonString
          ->Pulumi.Input.make,
          role: runtime.parts.lambdaRole.id->Pulumi.Output.asInput,
        },
      )

      // manageSubscriptions / reconcileSubscriptionsOnce / forwardCommand all
      // Scan the Plugin RM table to find connected peers + route forwarded
      // commands. The Plugin RM is owned by a separate ReadModel EC, so the
      // admin EC's default IAM policy does not include any DynamoDB perms on
      // it. Grant Scan only — the admin EC never writes here, projections
      // happen on the dedicated RM Lambda.
      switch config.pluginReadModelTableName {
      | Some(rmTableOutput) =>
        let policyJson =
          rmTableOutput->Pulumi.Output.apply(tableName =>
            PulumiAws.PolicyDocument.make(
              ~id=`${name}PluginRmScanPolicy`,
              ~statements=[
                {
                  sid: "AllowAdminScanPluginRm",
                  effect: Allow,
                  actions: Actions(["dynamodb:Scan"]),
                  resources: Resource("arn:aws:dynamodb:*:*:table/" ++ tableName),
                },
              ],
            )->PulumiAws.PolicyDocument.toJsonString
          )
        let _ = PulumiAws.IAM.RolePolicy.make(
          ~name=`${name}-pluginRmScan`,
          ~args={
            policy: policyJson->Pulumi.Output.asInput,
            role: runtime.parts.lambdaRole.id->Pulumi.Output.asInput,
          },
        )
      | None => ()
      }

      // mkUpdateApiSchema reads each plugin's deploy-time SDL fragment from the
      // dedicated PluginSchemaPersistence table (deploy-schema:<name> rows) to
      // re-stitch the live schema. Grant Scan on that table too — it is owned by
      // Platform.res, so the admin EC's default policy includes no perms on it.
      switch config.pluginSchemaPersistenceTableName {
      | Some(schemaTableOutput) =>
        let policyJson =
          schemaTableOutput->Pulumi.Output.apply(tableName =>
            PulumiAws.PolicyDocument.make(
              ~id=`${name}PluginSchemaScanPolicy`,
              ~statements=[
                {
                  sid: "AllowAdminScanPluginSchemaPersistence",
                  effect: Allow,
                  actions: Actions(["dynamodb:Scan"]),
                  resources: Resource("arn:aws:dynamodb:*:*:table/" ++ tableName),
                },
              ],
            )->PulumiAws.PolicyDocument.toJsonString
          )
        let _ = PulumiAws.IAM.RolePolicy.make(
          ~name=`${name}-pluginSchemaScan`,
          ~args={
            policy: policyJson->Pulumi.Output.asInput,
            role: runtime.parts.lambdaRole.id->Pulumi.Output.asInput,
          },
        )
      | None => ()
      }
    }
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
      let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
        ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/HeartbeatEntryPoint.mjs",
        ~packageDirs=Dict.make(),
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
    }
  }

  let forDcbCommandTopic: ReventlessCore.Runtime.forComponent<
    ReventlessCore.Runtime.effectHandler<'callbackEvent, context, unit, string>,
    runtimeParts,
    ReventlessCore.CommandTopic.component<'op>,
  > = (
    ~handler as _,
    ~connect,
    // memorySize/timeout are part of the Runtime.forComponent signature for
    // back-compat; per-Lambda tuning now flows through `commandHandlerConfig`.
    ~memorySize as _=1024,
    ~timeout as _=30,
    dcbCommandTopic,
  ) => {
    let dcbConfig = dcbConfigRef.contents
    // Merge slice module paths: auto-registered (from moduleUrl) + manually registered (from registerDcbConfig)
    let allSlicePaths =
      registeredSliceModulePaths->Array.concat(dcbConfig.stateChangeSliceModulePaths)
    if allSlicePaths->Array.length == 0 {
      Console.warn("PluginRuntime_Builder: forDcbCommandTopic skipped (no slice specs)")
    } else {
      let commandTopicResource = dcbCommandTopic->ReventlessCore.Component.toPulumiResource
      // The CommandTopic resource is already named `<Plugin>StateChanges` or
      // `<Plugin>StateChangesAsync` by Dcb_Builder — don't append the
      // `CommandTopic` componentType suffix again on the Lambda.
      let name = commandTopicResource.name->Option.getOr("UnnamedDcb")
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

      // The async DCB CommandTopic is named `<Plugin>StateChangesAsync` by
      // Dcb_Builder, so the canonical name's `Async` suffix is an unambiguous
      // signal. Flip DcbCommandTopicEntryPoint into async dispatch — Route 1
      // returns CommandPending instead of running the slice handler inline.
      let isAsync = name->String.endsWith("Async")

      let cfg = isAsync ? asyncStateChangesConfigRef.contents : syncStateChangesConfigRef.contents

      let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
      envVars->Dict.set("DCB_TABLE", dcbTableName->Pulumi.Output.asInput)
      envVars->Dict.set("QUEUE_URL", queue.id->Pulumi.Output.asInput)
      if isAsync {
        envVars->Dict.set("DISPATCH_MODE", "async"->Pulumi.Input.make)
      }
      cfg.envVars->Option.forEach(extra =>
        extra->Dict.forEachWithKey((value, key) => {
          if envVars->Dict.get(key)->Option.isNone {
            envVars->Dict.set(key, value->Pulumi.Output.make->Pulumi.Output.asInput)
          }
        })
      )

      // Build HANDLER_CONFIG JSON: array of {spec, behavior} objects so the entry point
      // can dynamically import both modules and apply the curried StateChangeSlice_Callback.Make
      // functor (Make(Spec)(Behavior)).
      let sliceModulesJson =
        allSlicePaths
        ->Array.map(({specPath, behaviorPath}) => {
          let s = specPath->JSON.stringifyAny->Option.getOr(`""`)
          let b = behaviorPath->JSON.stringifyAny->Option.getOr(`""`)
          `{"spec":${s},"behavior":${b}}`
        })
        ->Array.join(",")

      let handlerConfigJson =
        Pulumi.Output.all2((dcbTableName, queue.id))
        ->Pulumi.Output.apply(((table, queueUrl)) => {
          let pluginName =
            dcbConfig.pluginName->JSON.stringifyAny->Option.getOr(`""`)
          `{"dcbEventLogTableName":"${table}","queueUrl":"${queueUrl}","pluginName":${pluginName},"stateChangeSliceModules":[${sliceModulesJson}]}`
        })
      envVars->Dict.set("HANDLER_CONFIG", handlerConfigJson->Pulumi.Output.asInput)

      // Build code asset
      let packageDirs: dict<string> = Dict.make()
      allSlicePaths->Array.forEach(({specPath, behaviorPath}) => {
        let specPkg = Util_Bundle.extractPackageName(specPath)
        packageDirs->Dict.set(specPkg, Util_Bundle.resolvePackageRoot(specPkg))
        let behaviorPkg = Util_Bundle.extractPackageName(behaviorPath)
        packageDirs->Dict.set(behaviorPkg, Util_Bundle.resolvePackageRoot(behaviorPkg))
      })
      // Include reventless-aws itself so hand-written entry point (.mjs) files
      // in the zip take precedence over the Lambda layer, ensuring the latest
      // local version is used.
      packageDirs->Dict.set(
        "@reventlessdev/reventless-aws",
        Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-aws"),
      )

      let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
        ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/DcbCommandTopicEntryPoint.mjs",
        ~packageDirs,
      )

      cfg.sqsBatchSize->Option.forEach(CommandTopicChannel.SQS.setBatchSize)

      let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
        ~name,
        ~code,
        ~sourceCodeHash,
        ~envVars,
        ~memorySize=?cfg.memorySize,
        ~timeout=?cfg.timeout,
        ~reservedConcurrency=?cfg.reservedConcurrency,
        ~ephemeralStorageMb=?cfg.ephemeralStorageMb,
        ~logRetentionDays=?cfg.logRetentionDays,
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
      CommandTopicChannel.SQS.clearBatchSize()
    }
  }

  let finish = () => ()
}
