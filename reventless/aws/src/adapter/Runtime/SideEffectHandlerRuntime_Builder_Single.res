module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

let log = ReventlessCore.Logger.fromEnv()

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type sideEffectInfo = {
  sideEffectModulePaths: array<string>,
}

let sideEffectInfos: dict<sideEffectInfo> = Dict.make()

let registerSideEffectHandler = (~sideEffectHandlerName, ~sideEffectModulePaths) =>
  sideEffectInfos->Dict.set(sideEffectHandlerName, {sideEffectModulePaths: sideEffectModulePaths})

// Extra Lambda env vars contributed by bespoke side effects.
// The shared "AllSideEffectHandlers" Lambda is built once in finish(); all registered
// entries are merged onto its env there. Deploy-derived config only — never overrides
// HANDLER_CONFIG.
let extraEnvVarsAll: dict<Pulumi.Input.t<string>> = Dict.make()

let registerExtraEnv = (~extraEnvVars: dict<Pulumi.Input.t<string>>) =>
  extraEnvVars->Dict.forEachWithKey((v, k) => extraEnvVarsAll->Dict.set(k, v))

type storedSpec = {
  componentName: string,
  parentResource: Pulumi.Resource.t,
  sourceUrns: Pulumi.Output.t<array<string>>,
  channelSpec: ReventlessCore.EventCollector_Adapter.channelSpec<
    EventCollectorChannel.callbackEvent,
    context,
    EventCollectorChannel.channelParts,
  >,
  memorySize: int,
  timeout: int,
}

let storedSpecs: array<storedSpec> = []
let grandParent = ref(None)

let forEventCollector: ReventlessCore.Runtime.forEventCollector<
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
  let eventCollectorResource = eventCollector->ReventlessCore.Component.toPulumiResource
  let channel = eventCollector->ReventlessCore.EventCollector_Adapter.channel
  let eventCollectorName = eventCollectorResource.name->Option.getOr("Unnamed")

  switch eventCollectorResource.parent {
  | Some(parentResource) =>
    let parentName = parentResource.name->Option.getOr("Unnamed")
    if grandParent.contents == None {
      grandParent := parentResource.parent
    }

    let sourceUrns =
      (eventCollector->ReventlessCore.Component.outputs).resources
      ->Array.map(({urn}) => urn)
      ->Pulumi.Output.all

    storedSpecs
    ->Array.push({
      componentName: parentName,
      parentResource,
      sourceUrns,
      channelSpec: {channel, eventTopics, resources},
      memorySize,
      timeout,
    })
    ->ignore

    log.info(
      ~comp="SideEffectHandlerRuntime_Builder_Single",
      `registered ${eventCollectorName} for ${parentName}`,
    )
  | None =>
    JsError.throwWithMessage(
      `forEventCollector(single): eventCollector ${eventCollectorName} has no parent`,
    )
  }
}

let finished = ref(false)

let finish = () =>
  if !finished.contents {
    if storedSpecs->Array.length > 0 {
      let (maxMemorySize, maxTimeout) = storedSpecs->Array.reduce((0, 0), (
        (accMemorySize, accTimeout),
        {memorySize, timeout},
      ) => {
        (Math.Int.max(accMemorySize, memorySize), Math.Int.max(accTimeout, timeout))
      })

      switch grandParent.contents {
      | Some(parent) =>
        let opts = {Pulumi.ComponentResource.parent: parent}

        // Build HANDLER_CONFIG as a single JSON env var.
        let handlerOutputs: array<Pulumi.Output.t<string>> = []
        let packageDirs: dict<string> = Dict.make()

        storedSpecs->Array.forEach(spec => {
          switch sideEffectInfos->Dict.get(spec.componentName) {
          | Some(info) =>
            // Collect unique user packages for the code asset
            info.sideEffectModulePaths->Array.forEach(modPath => {
              let pkg = Util_Bundle.extractPackageName(modPath)
              packageDirs->Dict.set(pkg, Util_Bundle.resolvePackageRoot(pkg))
            })

            // Build JSON array of module paths
            let modulesJson =
              info.sideEffectModulePaths
              ->Array.map(p => p->JSON.stringifyAny->Option.getOr(`""`))
              ->Array.join(",")

            // Log attribution for the shared Lambda, resolved at deploy time —
            // the shell has only module paths to go on, and LogPrefix's registry
            // is a deploy-time structure
            // (docs/plans/entrypoint-dispatch-parity-and-latency-fields.md).
            let attribution = Util_LogAttribution.fragments(
              ~comp=`SideEffectHandler(${spec.componentName})`,
            )
            let handlerJson =
              spec.sourceUrns
              ->Pulumi.Output.apply(urns => {
                let sourceUrn = urns->Array.getUnsafe(0)
                `{"sideEffectModules":[${modulesJson}],"sourceUrn":"${sourceUrn}"${attribution}}`
              })
            let _ = handlerOutputs->Array.push(handlerJson)
          | None =>
            log.warn(
              ~comp="SideEffectHandlerRuntime_Builder_Single",
              `no handler registered for ${spec.componentName}`,
            )
          }
        })

        let handlerConfigOutput =
          Pulumi.Output.all(handlerOutputs)
          ->Pulumi.Output.apply(handlers =>
            `{"handlers":[${handlers->Array.join(",")}]}`
          )

        let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
        envVars->Dict.set("HANDLER_CONFIG", handlerConfigOutput->Pulumi.Output.asInput)
        // Merge bespoke side-effect config (never overrides HANDLER_CONFIG).
        extraEnvVarsAll->Dict.forEachWithKey((v, k) =>
          if k != "HANDLER_CONFIG" {
            envVars->Dict.set(k, v)
          }
        )

        // Build AssetArchive: static re-export + user packages
        let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
          ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/SideEffectEntryPoint.mjs",
          ~packageDirs,
        )

        let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
          ~name="AllSideEffectHandlers",
          ~unitKind=ReventlessCore.Monitoring.Reactor,
          ~code,
          ~sourceCodeHash,
          ~envVars,
          ~memorySize=maxMemorySize,
          ~timeout=maxTimeout,
          ~opts,
        )

        // Grant AppSync schema perms to the shared side-effect-handler Lambda
        // role ONLY when a bespoke side effect registered extra-env config —
        // Task-only deployments keep the narrow default perimeter. (The last
        // such contributor, the admin ApiSchemaPush, was retired with the
        // merged-API cutover; the mechanism stays for future bespoke effects.)
        if extraEnvVarsAll->Dict.keysToArray->Array.length > 0 {
          let _ = PulumiAws.IAM.RolePolicy.make(
            ~name="AllSideEffectHandlers-appsyncSchemaPush",
            ~args={
              policy: PulumiAws.PolicyDocument.make(
                ~id="AllSideEffectHandlersAppsyncSchemaPushPolicy",
                ~statements=[
                  {
                    sid: "AllowSideEffectStartSchemaCreation",
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
        }

        let channelSpecs = storedSpecs->Array.map(({channelSpec}) => channelSpec)
        let _connectResources = EventCollectorChannel.connect(
          ~name="AllSideEffectHandlers",
          ~channelSpecs,
          ~runtime,
          ~opts,
        )
      | None =>
        log.warn(
          ~comp="SideEffectHandlerRuntime_Builder_Single",
          `finish: grandParent not set`,
        )
      }
    }
    finished := true
  }
