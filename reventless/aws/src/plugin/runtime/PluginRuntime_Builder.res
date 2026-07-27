let log = ReventlessCore.Logger.fromEnv()

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

// InboundTranslationSlice registration for the shared DCB command Lambda. Unlike
// StateChangeSlices (routed by command TAG), inbound slices are invoked directly
// by their AppSync mutation resolver with an `__inboundTranslation` payload — the
// entry point routes those to a `receive` handler built from the spec + translation
// modules. Registration is two-phase: the AWS `InboundTranslationSlice_Builder`
// functor registers the module paths at instantiation (spec/translation `moduleUrl`,
// like StateChangeSlice), and its wrapped `make` registers the audit QueryDb's
// resolved table-name Output once the component is constructed (the physical name
// is Pulumi-generated, so it can't be reconstructed at runtime). Both fire before
// `forDcbCommandTopic` reads them.
type inboundSliceReg = {
  specPath: string,
  translationPath: string,
  // Plain `Pulumi.Output.t<string>`, never `option<Pulumi.Output.t<string>>`:
  // any generic `Option.*` call over an Output runs `valFromOption`, whose
  // `.BS_PRIVATE_NESTED_SOME_NONE` probe hits the Output proxy (every property
  // access returns a truthy Output), mis-classifies it as a nested-option and
  // corrupts it into `{BS_PRIVATE_NESTED_SOME_NONE:0}`. The empty-string Output
  // is the "no audit table" sentinel (serialized as `null` downstream).
  mutable auditTableName: Pulumi.Output.t<string>,
}
let registeredInboundSlices: dict<inboundSliceReg> = Dict.make()

let registerInboundTranslationSliceSpec = (
  ~specName: string,
  ~specPath: string,
  ~translationPath: string,
) =>
  switch registeredInboundSlices->Dict.get(specName) {
  | Some(reg) => registeredInboundSlices->Dict.set(specName, {...reg, specPath, translationPath})
  | None =>
    registeredInboundSlices->Dict.set(
      specName,
      {specPath, translationPath, auditTableName: Pulumi.Output.make("")},
    )
  }

let registerInboundAuditTableName = (~specName: string, tableName: Pulumi.Output.t<string>) =>
  switch registeredInboundSlices->Dict.get(specName) {
  | Some(reg) => reg.auditTableName = tableName
  | None =>
    registeredInboundSlices->Dict.set(
      specName,
      {specPath: "", translationPath: "", auditTableName: tableName},
    )
  }

/**
Redundant with the seams that populate `dcbConfigRef` automatically:
`pluginName` is set by `registerPluginName` (called from `Plugin_Builder.make`
when the plugin builds), the DCB table name by `registerDcbTableName`, and slice
module paths by `registerStateChangeSliceSpec` (from each slice's `moduleUrl`).
No deploy program needs to call this. Kept only so any out-of-tree caller still
compiles; slated for removal.
*/
@deprecated(
  "pluginName is auto-registered by Plugin_Builder.make; use registerDcbTableName / registerStateChangeSliceSpec for the other fields. This call is unnecessary and will be removed."
)
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

// heartbeatTimeout is mandatory: it drives the HEARTBEAT_TIMEOUT env var (and thus
// the Heartbeat(interval) command the bundled Lambda emits), which must match the
// EventBridge schedule rate derived from the same heartbeatInterval. A default here
// silently decoupled the two (schedule every 60min, Heartbeat(10) → 12min grace →
// flapping); make callers supply it so the values can't diverge.
let registerHeartbeatConfig = (~pluginId, ~heartbeatTimeout, ~epQueueUrl=?, ()) =>
  heartbeatConfigRef := {pluginId, heartbeatTimeout, epQueueUrl}

// Per-flavor commandHandlerConfig override for the two DCB command-handler Lambdas
// (`<Plugin>DcbCmdHandler` sync / `<Plugin>DcbAsyncCmdHandler` async); populated by
// Platform.MakeWithConfig from `commandHandlerConfig.stateChanges.{sync,async}`.
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

// PluginRuntime_Builder is a functor so that the caller can inject the EventCollectorChannel
// implementation. All other runtime builders hardcode EventCollectorChannel.DynamoDbStream, but
// the Plugin admin handler (EventCollectorEntryPoint) is shared across DCB and aggregate
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
    // (optional fields encoded as null via js_nullable). Must stay byte-aligned with
    // the ReScript-built twin in `Platform_Admin.construct`'s `fakePluginDefinition`.
    let platformId = ReventlessCore.Platform_Admin_Structure.pluginId
    let fakePluginDefinitionJson =
      `{"id":"${platformId}@INTERNAL","name":"${platformId}","version":"INTERNAL","extensionPoints":[],"extensions":[],"eventCollector":"NOT-SET","extensionProtocols":[],"apiSchemaFragment":null,"apiTarget":null,"structure":null}`->Pulumi.Output.make
    let adminEpEventTopicArn = switch config.eventTopicArn {
    | Some(arn) => arn
    | None => Pulumi.Output.make("NOT_AVAILABLE")
    }
    {
      pluginDefinitionJson: fakePluginDefinitionJson,
      // Admin ships no UI-fragment manifest.
      uiFragmentsJson: "null"->Pulumi.Output.make,
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

    // B2.3d: if this plugin's DCB log is Postgres-backed, hand its EventCollector
    // SQS queue to the change-feed relay registry. `resource.name` is the plugin
    // component name (`<plugin>Plugin`), so the canonical log_name is
    // `<plugin>DcbEventLog` — the key DcbEventLogStorage_Postgres registered under.
    if DcbBackend.isPostgres() {
      switch resource.name {
      | Some(compName) =>
        let pluginName =
          compName->String.endsWith("Plugin")
            ? compName->String.slice(~start=0, ~end=compName->String.length - 6)
            : compName
        DcbBackend.attachCollectorQueue(
          ~logName=pluginName ++ "DcbEventLog",
          ~url=queue.id,
          ~arn=queue.arn,
        )
      | None => ()
      }
    }

    // Classic Postgres logs: `~eventTopics` is keyed by aggregate name, so each key
    // attaches this plugin's EventCollector queue to exactly the aggregates whose
    // event-log DynamoDB stream the collector would have subscribed on the DynamoDB
    // path (admin's extension-point filtering included).
    if EventLogBackend.isPostgres() {
      eventTopics
      ->Dict.keysToArray
      ->Array.forEach(aggregateName =>
        EventLogBackend.attachCollectorQueue(~aggregateName, ~url=queue.id, ~arn=queue.arn)
      )
    }

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

        let dict = Dict.make()
        dict->Dict.set("queueUrl", JSON.Encode.string(queueUrl))
        dict->Dict.set("pluginExtensionPointCmdTopicUrl", JSON.Encode.string(pluginEpCmdTopicUrl))
        dict->Dict.set("eventTopicArn", JSON.Encode.string(topLevelEventTopicArn))
        dict->Dict.set("pluginReadModelTableName", JSON.Encode.string(rmTable))
        dict->Dict.set("appSyncApiId", JSON.Encode.string(appSyncApiId))
        dict->Dict.set("clonerEnabled", JSON.Encode.bool(config.clonerEnabled))
        dict->Dict.set("schedulerRoleArn", JSON.Encode.string(schedRoleArn))
        dict->Dict.set("schedulerQueueArn", JSON.Encode.string(schedQueueArn))
        dict->Dict.set("schedulerQueueName", JSON.Encode.string(schedQueueName))

        // pluginDefinition lives in pluginDefinition.json (see asset bundle
        // below). The entry point reads it via fs.readFileSync at cold start.

        // Pair each EP with its already-resolved eventTopicArn (parallel arrays)
        // BEFORE sorting, so the (ep, arn) pairing survives the reorder. Then
        // sort by ep.specModule for stable JSON output across deploys — without
        // this, push-order drift in upstream Dict iteration produces pointless
        // Lambda env-var "updates" on every `pulumi up`.
        let extensionPointsArr =
          context.extensionPoints
          ->Array.mapWithIndex((ep, i) => (ep, epEventTopicArns->Array.getUnsafe(i)))
          ->Array.toSorted(((a, _), (b, _)) => String.compare(a.specModule, b.specModule))
          ->Array.map(((ep, eventTopicArn)) => {
            let entryDict = Dict.make()
            entryDict->Dict.set("specModule", JSON.Encode.string(ep.specModule))
            entryDict->Dict.set("mappingsModule", JSON.Encode.string(ep.mappingsModule))
            entryDict->Dict.set("eventTopicArn", JSON.Encode.string(eventTopicArn))
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
        // Sort by extension name so the serialized JSON is stable across deploys.
        let extensionsArr =
          context.extensions
          ->Array.toSorted((a, b) => String.compare(a.name, b.name))
          ->Array.map(ext => {
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
    let addPackageFor = spec => {
      let pkgName = Util_Bundle.extractPackageName(spec)
      packageDirs->Dict.set(pkgName, Util_Bundle.resolvePackageRoot(pkgName))
    }
    context.extensions->Array.forEach(ext => {
      [ext.specModule, ext.mappingsModule, ext.delegateModule]->Array.forEach(addPackageFor)
    })
    // Outgoing EPs: the entry point dynamic-imports ep.specModule and
    // ep.mappingsModule at cold start (EventCollectorEntryPoint.mjs).
    // Without this walk the EP spec package (e.g. <plugin>-spec) is missing
    // from the asset zip even though HANDLER_CONFIG references it, and the
    // Lambda crashes with MODULE_NOT_FOUND before any event is processed.
    context.extensionPoints->Array.forEach(ep => {
      [ep.specModule, ep.mappingsModule]->Array.forEach(addPackageFor)
    })
    // The auto-included PluginConnectExtension entry is also dynamic-imported
    // at cold start. Its modules live in reventless-infra / reventless-core,
    // which are explicitly bundled below — walking it here is defensive but
    // costs nothing once those entries dedupe in packageDirs.
    switch context.connectExtension {
    | Some(ce) => [ce.specModule, ce.mappingsModule]->Array.forEach(addPackageFor)
    | None => ()
    }
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
      (context.pluginDefinitionJson, context.uiFragmentsJson)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((pluginDefinitionJson, uiFragmentsJson)) => {
        let extraStringAssets = Dict.make()
        extraStringAssets->Dict.set("pluginDefinition.json", pluginDefinitionJson)
        // The UI-fragment manifest no longer rides pluginDefinition — ship it as
        // its own asset ("null" for plugins without a UI) so the bundled Connect
        // extension can emit RegisterUiFragment in the handshake answer.
        extraStringAssets->Dict.set("uiFragments.json", uiFragmentsJson)
        Util_Bundle.buildCodeArchive(
          // Path string, not a module reference — a rename that misses this stays green
          // at build time and fails at bundle time or Lambda cold start.
          ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/EventCollectorEntryPoint.mjs",
          ~packageDirs,
          ~extraStringAssets,
        )
      })
    let codeOutput = bundleOutput->Pulumi.Output.apply(b => b.code)
    let sourceCodeHashOutput = bundleOutput->Pulumi.Output.apply(b => b.sourceCodeHash)

    let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
      ~name,
      ~unitKind=ReventlessCore.Monitoring.EventCollector,
      ~componentKind=ReventlessCore.ComponentType.EventCollector,
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

    }

    // Plugin EC sqs:SendMessage grants on the aggregate / StateChangeSlice
    // command-topic queues that user extensions publish to. The default
    // AllowLambdaSendSQS only covers PlatformPluginExtPointCmdTopic (added because
    // the auto-included Connect extension publishes there), so without this
    // grant every cross-plugin extension's first command publish fails with
    // IAM AccessDenied (e.g. Catalog's Orders_Extension → RecordProductDemand).
    //
    // We deliberately walk context.extensions[].aggregateNames rather than
    // Dict.valuesToArray over context.publishToAggregates: the dict is
    // declared as dict<Output<string>> but Plugin_Builder.res:322 also writes
    // Output<publishJsons> (function values) under DCB slice names — the type
    // is a polite lie, and the function-valued entries make a blanket .apply
    // over the values blow up at preview with "queueUrlOutput.apply is not a
    // function". Iterating extensions limits us to the names extensions
    // actually target, which are always backed by real URL Outputs in the
    // dict (mergedAggregateUrls / aggregateQueueUrls — Plugin_Builder.res:629).
    let aggregateNameSet = Dict.make()
    context.extensions->Array.forEach(ext =>
      ext.aggregateNames->Array.forEach(aggName =>
        aggregateNameSet->Dict.set(aggName, ())
      )
    )
    // One RolePolicy per extension target, each derived through a SINGLE
    // `.apply` on that target's queue-URL Output. `Pulumi.Output.all` is
    // deliberately NOT used here: the DCB slice's URL is an `.apply`-lifted
    // Output (Dcb_Builder reads the queue id via `operations.apply(_ =>
    // resources[0].id)`), and `Pulumi.Output.all` mis-resolves such lifted
    // Outputs to the `{BS_PRIVATE_NESTED_SOME_NONE: 0}` sentinel (both at
    // preview and up) while a direct `.apply` on the same Output resolves the
    // real URL — verified by deploying both variants. RolePolicy creation
    // happens at TOP LEVEL: calling `RolePolicy.make` inside a
    // `Pulumi.Output.apply` callback does not reliably register the resource
    // (the previous inside-apply variant existed on no collector role in the
    // account). Dict values are heterogeneous at runtime — plain resolved URL
    // strings for aggregate targets, Outputs for DCB-slice targets; anything
    // else is skipped. Inside the apply a non-string URL falls back to a
    // benign placeholder ARN so the policy document stays valid (IAM rejects
    // empty Resource entries with MalformedPolicyDocument).
    // See docs/analysis/ec-publish-to-aggregates-grant-broken.md.
    aggregateNameSet
    ->Dict.keysToArray
    ->Array.forEach(aggName => {
      let urlOutput = switch context.publishToAggregates->Dict.get(aggName) {
      | Some(o) if Pulumi.Output.isOutput(o) => Some(o)
      | Some(o) if typeof(o) === #string => Some(Pulumi.Output.make((o->Obj.magic: string)))
      | _ => None
      }
      switch urlOutput {
      | Some(urlOutput) =>
        let policyJson = urlOutput->Pulumi.Output.apply(url => {
          let arn = if typeof(url) === #string {
            // queue URL → ARN: https://sqs.<region>.amazonaws.com/<acct>/<name>
            //                → arn:aws:sqs:<region>:<acct>:<name>
            switch url->String.split("/") {
            | [_, _, host, acct, name] =>
              let region = host->String.split(".")->Array.get(1)->Option.getOr("eu-west-1")
              `arn:aws:sqs:${region}:${acct}:${name}`
            | _ => url
            }
          } else {
            "arn:aws:sqs:eu-west-1:000000000000:reventless-unresolved-cmd-topic"
          }
          PulumiAws.PolicyDocument.make(
            ~id=`${name}Pta${aggName}Policy`,
            ~statements=[
              {
                sid: "AllowEcPublishToAggregateCmdTopic",
                effect: Allow,
                actions: Action("sqs:SendMessage"),
                resources: Resource(arn),
              },
            ],
          )->PulumiAws.PolicyDocument.toJsonString
        })
        let _ = PulumiAws.IAM.RolePolicy.make(
          ~name=`${name}-pta-${aggName}`,
          ~args={
            policy: policyJson->Pulumi.Output.asInput,
            role: runtime.parts.lambdaRole.id->Pulumi.Output.asInput,
          },
        )
      | None => ()
      }
    })
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
      log.warn(~comp="PluginRuntime_Builder", "forPluginHeartbeat skipped (no EP queue URL)")
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
        ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/HeartbeatEntryPoint.res.mjs",
        ~packageDirs=Dict.make(),
      )

      let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
        ~name,
        ~unitKind=ReventlessCore.Monitoring.Scheduler,
        ~componentKind=ReventlessCore.ComponentType.Scheduler,
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

  // Thin delegator: supplies the registered slice paths + per-flavor config to
  // the build in StateChangeSliceRuntime_Builder_Single (kept as a named file so
  // it sits alongside StateViewSliceRuntime_Builder_Single, rather than buried
  // here). Merges slice module paths: auto-registered (from moduleUrl) + manually
  // registered (from registerDcbConfig).
  let forDcbCommandTopic: ReventlessCore.Runtime.forComponent<
    ReventlessCore.Runtime.effectHandler<'callbackEvent, context, unit, string>,
    runtimeParts,
    ReventlessCore.CommandTopic.component<'op>,
    // `~memorySize`/`~timeout` carry the per-component runtime floor (max across
    // this shared Lambda's StateChangeSlices' plugin.json overrides, 0 if none),
    // folded with the per-flavor commandHandlerConfig in the build below.
  > = (~handler as _, ~connect, ~memorySize=0, ~timeout=0, dcbCommandTopic) => {
    let dcbConfig = dcbConfigRef.contents
    let slicePaths =
      registeredSliceModulePaths
      ->Array.concat(dcbConfig.stateChangeSliceModulePaths)
      ->Array.map(({specPath, behaviorPath}) => (specPath, behaviorPath))
    // Drop registrations that never received their module paths (a bare
    // audit-table registration with no matching spec functor — shouldn't happen,
    // but keeps a half-registered slice out of HANDLER_CONFIG).
    let inboundSlices =
      registeredInboundSlices
      ->Dict.valuesToArray
      ->Array.filterMap(reg =>
        reg.specPath == ""
          ? None
          : Some(
              (
                {
                  StateChangeSliceRuntime_Builder_Single.specPath: reg.specPath,
                  translationPath: reg.translationPath,
                  auditTableName: reg.auditTableName,
                }: StateChangeSliceRuntime_Builder_Single.inboundSlicePaths
              ),
            )
      )
    StateChangeSliceRuntime_Builder_Single.forDcbCommandTopic(
      ~slicePaths,
      ~inboundSlices,
      ~dcbTableName=dcbConfig.dcbTableName,
      ~pluginName=dcbConfig.pluginName,
      ~syncConfig=syncStateChangesConfigRef.contents,
      ~asyncConfig=asyncStateChangesConfigRef.contents,
      ~sliceMemoryFloor=memorySize,
      ~sliceTimeoutFloor=timeout,
      ~connect,
      dcbCommandTopic,
    )
  }

  let finish = () => ()
}
