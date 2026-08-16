// Runtime builder for the DCB StateChange command-handler Lambda.
//
// Builds the `<Plugin>DcbCmdHandler` (sync) / `<Plugin>DcbAsyncCmdHandler` (async)
// Lambda that runs all of a plugin's StateChangeSlice command handlers — the
// "Single" deployment strategy (one shared Lambda per plugin). DCB StateChange
// has no other topology, so there is no `_PerSlice`/`_Micro` variant.
//
// Mirrors StateViewSliceRuntime_Builder_Single so the two DCB slice runtimes are
// discoverable side by side. The registration state (which slices, table name,
// per-flavor commandHandlerConfig) is plugin-runtime-level and stays in
// PluginRuntime_Builder; its `forDcbCommandTopic` is a thin delegator that reads
// those refs and calls the build below. This module owns only the build.

let log = ReventlessCore.Logger.fromEnv()

// `(specPath, translationPath)` module specifiers per InboundTranslationSlice,
// plus the resolved audit QueryDb table-name Output (None on the Postgres path or
// if the component hasn't reported it). The entry point imports both modules,
// builds `InboundTranslationSlice_Callback.Make(Spec)(Translation).receive`, and
// — when `auditTableName` is present — persists the audit rows to that table.
type inboundSlicePaths = {
  specPath: string,
  translationPath: string,
  // Plain Output, never `option<Pulumi.Output.t<string>>` — see the note on
  // `PluginRuntime_Builder.inboundSliceReg.auditTableName`. Empty string = no
  // audit table (serialized as `null`).
  auditTableName: Pulumi.Output.t<string>,
}

// `slicePaths`: `(specPath, behaviorPath)` per StateChangeSlice (already merged
// from auto- and manually-registered sources by the caller).
let forDcbCommandTopic = (
  ~slicePaths: array<(string, string)>,
  ~inboundSlices: array<inboundSlicePaths>=[],
  ~dcbTableName: option<Pulumi.Output.t<string>>,
  ~pluginName: string,
  ~syncConfig: ReventlessCore.Runtime.commandHandlerConfig,
  ~asyncConfig: ReventlessCore.Runtime.commandHandlerConfig,
  // Per-component runtime floor: the max across this shared Lambda's
  // StateChangeSlices' plugin.json `runtime` overrides (0 if none). Folded with
  // the per-flavor commandHandlerConfig below (whichever is higher wins).
  ~sliceMemoryFloor: int=0,
  ~sliceTimeoutFloor: int=0,
  ~connect,
  dcbCommandTopic,
) =>
  if slicePaths->Array.length == 0 && inboundSlices->Array.length == 0 {
    log.warn(
      ~comp="StateChangeSliceRuntime_Builder_Single",
      "forDcbCommandTopic skipped (no slice specs)",
    )
  } else {
    let commandTopicResource = dcbCommandTopic->ReventlessCore.Component.toPulumiResource
    // The CommandTopic resource is named `<Plugin>Dcb` (sync) or `<Plugin>DcbAsync`
    // (async) by Dcb_Builder. Detect async off that bare stem (below), then append
    // the canonical `CmdHandler` Lambda kind so the command-handler Lambda is
    // greppable alongside the aggregate lineage.
    let baseName = commandTopicResource.name->Option.getOr("UnnamedDcb")
    let opts = {Pulumi.ComponentResource.parent: commandTopicResource}

    // Extract SQS queue from the DCB CommandTopic
    let channel = dcbCommandTopic->ReventlessCore.CommandTopic_Adapter.channel
    let channelParts: Util.SQS.channelParts = Obj.magic(channel.parts)
    let queue = channelParts.queue

    // B2.3c: on a Postgres-backed platform there is no DynamoDB table — DCB events
    // live in `dcb_event` under the canonical log_name `<plugin>DcbEventLog`
    // (= ComponentType.name(_, DcbEventLog), the same string the deploy-time
    // storage + the change-feed relay use). The DcbCommandTopicEntryPoint Postgres
    // branch reads `dcbEventLogTableName` as that log_name.
    let pgSelection = DcbBackend.get()
    let dcbTableName = switch (pgSelection, dcbTableName) {
    | (Some(_), _) => Pulumi.Output.make(pluginName ++ "DcbEventLog")
    | (None, Some(tableName)) => tableName
    | (None, None) => Pulumi.Output.make("NOT_AVAILABLE")
    }

    // The async DCB CommandTopic is named `<Plugin>DcbAsync` by Dcb_Builder, so the
    // bare stem's `Async` suffix is an unambiguous signal. Flip
    // DcbCommandTopicEntryPoint into async dispatch — Route 1 returns CommandPending
    // instead of running the slice handler inline.
    let isAsync = baseName->String.endsWith("Async")
    let name = baseName ++ "CmdHandler"

    let cfg = isAsync ? asyncConfig : syncConfig
    // Fold the per-component runtime floor with the config: config wins when
    // higher, an override raises the shared Lambda above the per-kind default.
    let memorySize = Math.Int.max(
      cfg.memorySize->Option.getOr(ReventlessCore.Runtime.CommandHandlerDefaults.memorySize),
      sliceMemoryFloor,
    )
    let timeout = Math.Int.max(
      cfg.timeout->Option.getOr(ReventlessCore.Runtime.CommandHandlerDefaults.timeout),
      sliceTimeoutFloor,
    )

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
    // First-class log-level override → LOG_LEVEL, winning over any generic
    // envVars entry. When unset, makeFromCodeAsset applies the tier default.
    cfg.logLevel->Option.forEach(level =>
      envVars->Dict.set("LOG_LEVEL", level->Pulumi.Output.make->Pulumi.Output.asInput)
    )

    // The slice registry: an array of {spec, behavior} objects so the entry point
    // can dynamically import both modules and apply the curried StateChangeSlice_Callback.Make
    // functor (Make(Spec)(Behavior)).
    //
    // Shipped as a `sliceModules.json` asset rather than inline in HANDLER_CONFIG.
    // Two absolute module specifiers per slice is the one term here that grows
    // with the plugin, and a plugin with a dozen-odd slices carries enough of
    // them to pass Lambda's 4KB UpdateFunctionConfiguration ceiling on the whole
    // environment — the same wall `pluginDefinition` hit in PluginRuntime_Builder,
    // and it fails at deploy with the registry already committed to the stack.
    let sliceModulesJson =
      slicePaths
      ->Array.map(((specPath, behaviorPath)) => {
        let s = specPath->JSON.stringifyAny->Option.getOr(`""`)
        let b = behaviorPath->JSON.stringifyAny->Option.getOr(`""`)
        `{"spec":${s},"behavior":${b}}`
      })
      ->Array.join(",")

    // B2.3c: on Postgres, add a `pgConnection` object so the entry point selects the
    // Postgres DCB runtime (absent → DynamoDB path, unchanged). Built as a JSON
    // fragment merged into HANDLER_CONFIG below.
    let pgConnectionFragment = switch pgSelection {
    | Some(sel) =>
      // C2: the DCB command Lambda is the only Postgres path that takes an append
      // lock, so `lockStrategy` rides in this fragment (not in `connectionConfig`,
      // which the classic/QueryDb paths share). The entry point passes it to
      // `DcbEventLogStorage_Postgres_Runtime.opsFor`.
      sel.connectionConfig->Pulumi.Output.apply(cc =>
        `,"pgConnection":${cc
          ->PgConnection.connectionConfigToJson(~lockStrategy=sel.lockStrategy)
          ->JSON.stringify}`
      )
    | None => Pulumi.Output.make("")
    }

    // InboundTranslationSlice modules — spec + translation paths and the resolved
    // audit table name (Pulumi-generated, so it must be resolved here). Emitted as
    // a `,"inboundTranslationSliceModules":[…]` fragment merged into HANDLER_CONFIG
    // (absent → the entry point has no Route 0 registry, unchanged behaviour).
    let inboundFragment = switch inboundSlices {
    | [] => Pulumi.Output.make("")
    | slices =>
      slices
      ->Array.map(s => s.auditTableName)
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(tableNames => {
        let entries =
          slices
          ->Array.mapWithIndex((s, i) => {
            let spec = s.specPath->JSON.stringifyAny->Option.getOr(`""`)
            let translation = s.translationPath->JSON.stringifyAny->Option.getOr(`""`)
            let tableName = tableNames->Array.getUnsafe(i)
            let auditJson =
              tableName == "" ? "null" : tableName->JSON.stringifyAny->Option.getOr("null")
            `{"spec":${spec},"translation":${translation},"auditTableName":${auditJson}}`
          })
          ->Array.join(",")
        `,"inboundTranslationSliceModules":[${entries}]`
      })
    }

    let handlerConfigJson =
      Pulumi.Output.all4((dcbTableName, queue.id, pgConnectionFragment, inboundFragment))
      ->Pulumi.Output.apply(((table, queueUrl, pgFragment, inbFragment)) => {
        let pluginNameJson = pluginName->JSON.stringifyAny->Option.getOr(`""`)
        let json = `{"dcbEventLogTableName":"${table}","queueUrl":"${queueUrl}","pluginName":${pluginNameJson}${pgFragment}${inbFragment}}`
        Util_LambdaEnvBudget.check(~lambdaName=name, ~handlerConfigJson=json)
        json
      })
    envVars->Dict.set("HANDLER_CONFIG", handlerConfigJson->Pulumi.Output.asInput)

    // Build code asset
    let packageDirs: dict<string> = Dict.make()
    slicePaths->Array.forEach(((specPath, behaviorPath)) => {
      let specPkg = Util_Bundle.extractPackageName(specPath)
      packageDirs->Dict.set(specPkg, Util_Bundle.resolvePackageRoot(specPkg))
      let behaviorPkg = Util_Bundle.extractPackageName(behaviorPath)
      packageDirs->Dict.set(behaviorPkg, Util_Bundle.resolvePackageRoot(behaviorPkg))
    })
    // Inbound slice spec + translation packages the entry point imports for Route 0.
    inboundSlices->Array.forEach(s => {
      let specPkg = Util_Bundle.extractPackageName(s.specPath)
      packageDirs->Dict.set(specPkg, Util_Bundle.resolvePackageRoot(specPkg))
      let translationPkg = Util_Bundle.extractPackageName(s.translationPath)
      packageDirs->Dict.set(translationPkg, Util_Bundle.resolvePackageRoot(translationPkg))
    })
    // Include the framework packages alongside the entry point so the deployed
    // Lambda picks up uncommitted local changes without waiting for the Lambda
    // Layer rebuild (the layer fetches @reventlessdev/reventless-* from GitHub
    // Packages, not the local pnpm workspace). reventless-core is critical here
    // because StateChangeSlice_Callback (the actual command handler) lives in core.
    packageDirs->Dict.set(
      "@reventlessdev/reventless-aws",
      Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-aws"),
    )
    packageDirs->Dict.set(
      "@reventlessdev/reventless-core",
      Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-core"),
    )

    // Carries no Pulumi Output, so the archive is still built synchronously —
    // the audit table names that do are in the inbound fragment, which stays in
    // HANDLER_CONFIG.
    let extraStringAssets = Dict.make()
    extraStringAssets->Dict.set("sliceModules.json", `[${sliceModulesJson}]`)

    let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
      ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/DcbCommandTopicEntryPoint.mjs",
      ~packageDirs,
      ~extraStringAssets,
    )

    cfg.sqsBatchSize->Option.forEach(CommandTopicChannel.SQS.setBatchSize)

    // B2.3c: Postgres-backed DCB → the command Lambda talks to RDS, so it must land
    // in-VPC on the DB-access security group + private subnets. makeFromCodeAsset
    // adds the EC2-ENI IAM automatically when vpcConfig is present (C1).
    let vpcConfig = switch pgSelection {
    | Some(sel) =>
      Some(
        sel.securityGroupId
        ->Pulumi.Output.apply(sgId =>
          (
            {
              PulumiAws.Lambda.Function.subnetIds: sel.subnetIds->Pulumi.Input.make,
              securityGroupIds: [sgId->Pulumi.Input.make]->Pulumi.Input.make,
            }: PulumiAws.Lambda.Function.vpcConfig
          )
        )
        ->Pulumi.Output.asInput,
      )
    | None => None
    }

    let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
      ~name,
      ~unitKind=ReventlessCore.Monitoring.CommandHandler,
      ~componentKind=ReventlessCore.ComponentType.StateChangeSlice,
      ~code,
      ~sourceCodeHash,
      ~envVars,
      ~memorySize,
      ~timeout,
      ~reservedConcurrency=?cfg.reservedConcurrency,
      ~ephemeralStorageMb=?cfg.ephemeralStorageMb,
      ~logRetentionDays=?cfg.logRetentionDays,
      ~vpcConfig=?vpcConfig,
      // This is the StateChangeSlice command handler — provision the DCB
      // retry/conflict metric filters (takes effect when logRetentionDays is set).
      ~dcbMetrics=true,
      ~opts,
    )

    // B2.3c: grant the Postgres command Lambda read access to the RDS-managed
    // master secret so PgRuntime can resolve the DB password at cold start.
    switch pgSelection {
    | Some(sel) =>
      let _ = sel.connectionConfig->Pulumi.Output.apply(cc => {
        PulumiAws.IAM.RolePolicy.make(
          ~name=`${name}-pgSecret`,
          ~args={
            policy: PulumiAws.PolicyDocument.make(
              ~id=`${name}-pgSecretPolicy`,
              ~statements=[
                {
                  sid: "AllowGetPgSecret",
                  effect: Allow,
                  actions: Action("secretsmanager:GetSecretValue"),
                  resources: Resource(cc.secretArn),
                },
              ],
            )
            ->PulumiAws.PolicyDocument.toJsonString
            ->Pulumi.Input.make,
            role: runtime.parts.lambdaRole.id->Pulumi.Output.asInput,
          },
        )
      })
    | None => ()
    }

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
