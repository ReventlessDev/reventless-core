module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

let log = ReventlessCore.Logger.fromEnv()

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

// One StateViewSlice handler, carried structured (not pre-serialized) so
// buildLambda can hoist shared fields before emitting HANDLER_CONFIG.
type handlerEntry = {
  specModule: string,
  projectionModule: string,
  queryDbTableName: string,
  sourceUrn: string,
  // B3.3: AppSync Events channel root for a subscription-enabled Postgres view
  // slice; "" when the slice isn't live-enabled (compact key `t`, omitted then).
  stateTopicName: string,
}

// Longest common prefix of a set of strings. Used to factor the shared
// module-path prefix out of the per-handler config so the serialized
// HANDLER_CONFIG stays under AWS Lambda's 4KB env-var ceiling.
let commonPrefix = (strings: array<string>): string =>
  switch strings->Array.get(0) {
  | None => ""
  | Some(first) =>
    strings->Array.reduce(first, (prefix, s) => {
      let p = ref(prefix)
      while p.contents != "" && !(s->String.startsWith(p.contents)) {
        p := p.contents->String.slice(~start=0, ~end=String.length(p.contents) - 1)
      }
      p.contents
    })
  }

type sliceInfo = {
  specModulePath: string,
  projectionModulePath: string,
  queryDbTableName: Pulumi.Output.t<string>,
  queryDbResources: array<ReventlessInfra.Adapter.resource>,
}

let sliceInfos: dict<sliceInfo> = Dict.make()

// B3.3: the AppSync Events API a Postgres-backed stream view slice publishes live
// updates to. Set once by `Platform.makePlatform` before plugins build (mirrors
// EventCollectorRuntime_Builder_Single). None → no live updates.
type eventsApiConfig = {
  endpoint: Pulumi.Output.t<string>,
  apiArn: Pulumi.Output.t<string>,
}
let eventsApiConfig: ref<option<eventsApiConfig>> = ref(None)
let setEventsApiConfig = (cfg: eventsApiConfig) => eventsApiConfig := Some(cfg)

// Channel root for a subscription-enabled Postgres view slice (the plural LIST
// field name, same source as the DynamoDB subscriptionInfraHook); "" when the
// slice isn't stream-routed or there's no events API.
let stateTopicNameFor = (name: string): string =>
  QueryDbBackend.postgresStreamRegistry->Set.has(name) && eventsApiConfig.contents->Option.isSome
    ? ReventlessCore.Plugin_Helpers.queryFieldNamesRegistry
      ->Dict.get(name)
      ->Option.map(qn => qn.listFieldName)
      ->Option.getOr(name)
    : ""

let registerStateViewSlice = (
  ~name,
  ~specModulePath,
  ~projectionModulePath,
  ~queryDbTableName,
  ~queryDbResources=[],
) =>
  sliceInfos->Dict.set(
    name,
    {specModulePath, projectionModulePath, queryDbTableName, queryDbResources},
  )

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
      ~comp="StateViewSliceRuntime_Builder_Single",
      `registered ${eventCollectorName} for ${parentName}`,
    )
  | None =>
    JsError.throwWithMessage(
      `forEventCollector(single): eventCollector ${eventCollectorName} has no parent`,
    )
  }
}

let finished = ref(false)

let buildLambda = (
  ~parent,
  ~handlerOutputs: array<Pulumi.Output.t<handlerEntry>>,
  ~packageDirs,
  ~channelSpecs,
  ~feedQueue: option<PulumiAws.SQS.Queue.t>=None,
  // B3.3: Some when any slice on this Lambda is a subscription-enabled Postgres
  // view slice — arms the APPSYNC_ENDPOINT env + appsync:EventPublish IAM.
  ~pgStreamConfig: option<eventsApiConfig>=None,
  ~memorySize=1024,
  ~timeout=30,
) => {
  let opts = {Pulumi.ComponentResource.parent: parent}

  // B3.1: on a Postgres-backed platform every slice view table lives in
  // Postgres (slices are never admin-exempt) — one shared `pgConnection` is
  // hoisted to the top level of the compressed config, like base/sourceUrn.
  let qdbSelection = QueryDbBackend.get()
  let pgConnectionFragment = switch qdbSelection {
  | Some(sel) =>
    sel.connectionConfig->Pulumi.Output.apply(cc =>
      `,"pgConnection":${cc->PgConnection.connectionConfigToJson->JSON.stringify}`
    )
  | None => Pulumi.Output.make("")
  }

  // Compress HANDLER_CONFIG to stay under AWS Lambda's 4KB env-var ceiling:
  // hoist the common module-path prefix (`base`) and the shared DCB stream
  // `sourceUrn` (identical across a plugin's slices) out of the per-handler
  // entries, and use short keys (s/p/q/u). StateViewSliceEntryPoint re-expands
  // these. Durable fix (externalize to S3/SSM) tracked in docs/plans.
  let handlerConfigOutput =
    (Pulumi.Output.all(handlerOutputs), pgConnectionFragment)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((handlers, pgFragment)) => {
      let paths = []
      handlers->Array.forEach(h => {
        paths->Array.push(h.specModule)->ignore
        paths->Array.push(h.projectionModule)->ignore
      })
      let base = commonPrefix(paths)
      let baseLen = String.length(base)
      let firstUrn = handlers->Array.get(0)->Option.map(h => h.sourceUrn)
      let sharedUrn =
        handlers->Array.every(h => Some(h.sourceUrn) == firstUrn) ? firstUrn->Option.getOr("") : ""
      let entries =
        handlers
        ->Array.map(h => {
          let s =
            h.specModule
            ->String.slice(~start=baseLen, ~end=String.length(h.specModule))
            ->JSON.stringifyAny
            ->Option.getOr(`""`)
          let p =
            h.projectionModule
            ->String.slice(~start=baseLen, ~end=String.length(h.projectionModule))
            ->JSON.stringifyAny
            ->Option.getOr(`""`)
          let q = h.queryDbTableName->JSON.stringifyAny->Option.getOr(`""`)
          // B3.3: compact key `t` = live-update channel root; omit when empty.
          let t =
            h.stateTopicName == ""
              ? ""
              : `,"t":${h.stateTopicName->JSON.Encode.string->JSON.stringify}`
          if sharedUrn != "" {
            `{"s":${s},"p":${p},"q":${q}${t}}`
          } else {
            let u = h.sourceUrn->JSON.stringifyAny->Option.getOr(`""`)
            `{"s":${s},"p":${p},"q":${q},"u":${u}${t}}`
          }
        })
        ->Array.join(",")
      let baseJson = base->JSON.stringifyAny->Option.getOr(`""`)
      let urnJson = sharedUrn->JSON.stringifyAny->Option.getOr(`""`)
      let json = `{"v":2,"base":${baseJson},"sourceUrn":${urnJson},"handlers":[${entries}]${pgFragment}}`
      Util_LambdaEnvBudget.check(~lambdaName="AllStateViewSlices", ~handlerConfigJson=json)
      json
    })

  let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
  envVars->Dict.set("HANDLER_CONFIG", handlerConfigOutput->Pulumi.Output.asInput)

  // B3.3: give the projection Lambda the AppSync Events endpoint when any of its
  // slices publish live updates (IAM added below).
  switch pgStreamConfig {
  | Some(cfg) => envVars->Dict.set("APPSYNC_ENDPOINT", cfg.endpoint->Pulumi.Output.asInput)
  | None => ()
  }

  // Bundle the framework packages alongside the entry point so the deployed
  // Lambda picks up local edits without waiting for a Lambda Layer rebuild
  // (the layer fetches @reventlessdev/reventless-* from GitHub Packages, not
  // the local pnpm workspace). Mirrors the DCB asset pattern in
  // StateChangeSliceRuntime_Builder_Single. Util_Bundle co-bundles `effect`
  // automatically when reventless-aws is present.
  packageDirs->Dict.set(
    "@reventlessdev/reventless-aws",
    Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-aws"),
  )
  packageDirs->Dict.set(
    "@reventlessdev/reventless-core",
    Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-core"),
  )

  let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
    ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/StateViewSliceEntryPoint.mjs",
    ~packageDirs,
  )

  // Postgres-backed view tables → the projection Lambda writes to RDS, so it
  // must land in-VPC on the DB-access security group + private subnets.
  let vpcConfig = switch qdbSelection {
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
    ~name="AllStateViewSlices",
    ~unitKind=ReventlessCore.Monitoring.Projection,
    ~componentKind=ReventlessCore.ComponentType.StateViewSlice,
    ~code,
    ~sourceCodeHash,
    ~envVars,
    ~memorySize,
    ~timeout,
    ~vpcConfig=?vpcConfig,
    ~opts,
  )

  // Grant the Postgres-backed projection Lambda read access to the RDS-managed
  // master secret so PgRuntime can resolve the DB password at cold start.
  switch qdbSelection {
  | Some(sel) =>
    let _ = sel.connectionConfig->Pulumi.Output.apply(cc => {
      open PulumiAws.PolicyDocument
      PulumiAws.IAM.RolePolicy.make(
        ~name="AllStateViewSlices-pgSecret",
        ~args={
          policy: PulumiAws.PolicyDocument.make(
            ~id="AllStateViewSlices-pgSecretPolicy",
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

  // B3.3: grant appsync:EventPublish so subscription-enabled Postgres view slices
  // can push live-update descriptors from this Lambda.
  switch pgStreamConfig {
  | Some(cfg) =>
    let _ = cfg.apiArn->Pulumi.Output.apply(apiArn => {
      open PulumiAws.PolicyDocument
      PulumiAws.IAM.RolePolicy.make(
        ~name="AllStateViewSlices-appsyncPublish",
        ~args={
          policy: PulumiAws.PolicyDocument.make(
            ~id="AllStateViewSlices-appsyncPublishPolicy",
            ~statements=[
              {
                sid: "AllowPublishAppSyncEvents",
                effect: Allow,
                actions: Action("appsync:EventPublish"),
                resources: Resource(apiArn ++ "/*"),
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

  let _connectResources = EventCollectorChannel.connect(
    ~name="AllStateViewSlices",
    ~channelSpecs,
    ~runtime,
    ~opts,
  )

  // B3.0: wire the Postgres feed queue into the Lambda (ESM + receive IAM).
  switch feedQueue {
  | Some(queue) =>
    PgProjectionFeed.connect(
      ~name="AllStateViewSlicesFeed",
      ~queue,
      ~lambda=runtime.parts.lambda,
      ~lambdaRole=runtime.parts.lambdaRole,
      ~opts=opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions,
    )
  | None => ()
  }
}

let finishWithDcbEventLog = (dcbEventLog: ReventlessCore.DcbEventLog.component) =>
  if !finished.contents {
    let infoCount = sliceInfos->Dict.keysToArray->Array.length
    if infoCount > 0 {
      let dcbResource = dcbEventLog->ReventlessCore.Component.toPulumiResource
      switch dcbResource.parent {
      | Some(parent) =>
        let dcbOutputs: ReventlessCore.DcbEventLog.outputs = dcbEventLog->ReventlessCore.Component.outputs
        let eventTopics: ReventlessCore.EventTopic.allOutputs = Dict.fromArray([
          ("DcbEventLog", dcbOutputs.eventTopic),
        ])
        let channel = EventCollectorChannel.make(
          ~name="AllStateViewSlices",
          ~eventTopics,
          ~owner=None, ~opts={Pulumi.ComponentResource.parent: parent},
        )

        // B3.0: a Postgres-backed DCB log has no stream resource — provision the
        // SQS feed queue the change-feed relay fans DCB events into. Its ARN is
        // the handlers' sourceUrn dispatch key.
        let feedQueue = DcbBackend.isPostgres()
          ? Some(
              PgProjectionFeed.makeQueue(
                ~name="AllStateViewSlicesFeed",
                ~scope="aws-svs-feed",
                ~includeClassic=false,
                ~includeDcb=true,
                ~opts={Pulumi.CustomResourceOptions.parent: parent},
              ),
            )
          : None
        let feedArnOutput = switch feedQueue {
        | Some(queue) => queue.arn
        | None => Pulumi.Output.make("")
        }

        let handlerOutputs: array<Pulumi.Output.t<handlerEntry>> = []
        let packageDirs: dict<string> = Dict.make()
        let allQueryDbResources: array<ReventlessInfra.Adapter.resource> = []

        sliceInfos->Dict.forEachWithKey((info, name) => {
          info.queryDbResources->Array.forEach(r => allQueryDbResources->Array.push(r)->ignore)
          let specPkg = Util_Bundle.extractPackageName(info.specModulePath)
          packageDirs->Dict.set(specPkg, Util_Bundle.resolvePackageRoot(specPkg))
          let projectionPkg = Util_Bundle.extractPackageName(info.projectionModulePath)
          packageDirs->Dict.set(projectionPkg, Util_Bundle.resolvePackageRoot(projectionPkg))

          let etResources: array<ReventlessInfra.Adapter.resource> = dcbOutputs.eventTopic.resources
          // No stream resource (Postgres DCB) → dispatch on the feed queue ARN.
          let sourceUrn = switch etResources->Array.get(0) {
          | Some(resource) => resource.urn
          | None => feedArnOutput
          }

          let handlerJson =
            Pulumi.Output.all2((info.queryDbTableName, sourceUrn))
            ->Pulumi.Output.apply(((tableName, urn)) => {
              let entry: handlerEntry = {
                specModule: info.specModulePath,
                projectionModule: info.projectionModulePath,
                queryDbTableName: tableName,
                sourceUrn: urn,
                stateTopicName: stateTopicNameFor(name),
              }
              entry
            })
          let _ = handlerOutputs->Array.push(handlerJson)
        })

        let anyPgStream =
          sliceInfos
          ->Dict.keysToArray
          ->Array.some(n => QueryDbBackend.postgresStreamRegistry->Set.has(n))
        buildLambda(
          ~parent,
          ~handlerOutputs,
          ~packageDirs,
          ~channelSpecs=[{channel: channel, eventTopics, resources: allQueryDbResources}],
          ~feedQueue,
          ~pgStreamConfig=anyPgStream ? eventsApiConfig.contents : None,
        )
      | None =>
        log.warn(
          ~comp="StateViewSliceRuntime_Builder_Single",
          "finishWithDcbEventLog: DCB EventLog has no parent",
        )
      }
    }
    finished := true
  }

let finish = () =>
  if !finished.contents {
    log.info(
      ~comp="StateViewSliceRuntime_Builder_Single",
      `finish: ${storedSpecs->Array.length->Int.toString} storedSpecs, ${sliceInfos->Dict.keysToArray->Array.length->Int.toString} sliceInfos, grandParent=${grandParent.contents->Option.map(_ => "Some")->Option.getOr("None")}`,
    )
    if storedSpecs->Array.length > 0 {
      let (maxMemorySize, maxTimeout) = storedSpecs->Array.reduce((0, 0), (
        (accMemorySize, accTimeout),
        {memorySize, timeout},
      ) => {
        (Math.Int.max(accMemorySize, memorySize), Math.Int.max(accTimeout, timeout))
      })

      switch grandParent.contents {
      | Some(parent) =>
        let handlerOutputs: array<Pulumi.Output.t<handlerEntry>> = []
        let packageDirs: dict<string> = Dict.make()

        // B3.0: Postgres-backed source logs have no stream — feed queue instead.
        let feedQueue = DcbBackend.isPostgres()
          ? Some(
              PgProjectionFeed.makeQueue(
                ~name="AllStateViewSlicesFeed",
                ~scope="aws-svs-feed",
                ~includeClassic=false,
                ~includeDcb=true,
                ~opts={Pulumi.CustomResourceOptions.parent: parent},
              ),
            )
          : None
        let feedArnOutput = switch feedQueue {
        | Some(queue) => queue.arn
        | None => Pulumi.Output.make("")
        }

        storedSpecs->Array.forEach(spec => {
          switch sliceInfos->Dict.get(spec.componentName) {
          | Some(info) =>
            let specPkg = Util_Bundle.extractPackageName(info.specModulePath)
            packageDirs->Dict.set(specPkg, Util_Bundle.resolvePackageRoot(specPkg))
            let projectionPkg = Util_Bundle.extractPackageName(info.projectionModulePath)
            packageDirs->Dict.set(projectionPkg, Util_Bundle.resolvePackageRoot(projectionPkg))

            let handlerJson =
              Pulumi.Output.all3((info.queryDbTableName, spec.sourceUrns, feedArnOutput))
              ->Pulumi.Output.apply(((tableName, urns, feedArn)) => {
                let entry: handlerEntry = {
                  specModule: info.specModulePath,
                  projectionModule: info.projectionModulePath,
                  queryDbTableName: tableName,
                  // No stream resource (Postgres) → dispatch on the feed queue ARN.
                  sourceUrn: urns->Array.get(0)->Option.getOr(feedArn),
                  stateTopicName: stateTopicNameFor(spec.componentName),
                }
                entry
              })
            let _ = handlerOutputs->Array.push(handlerJson)
          | None =>
            log.warn(
              ~comp="StateViewSliceRuntime_Builder_Single",
              `no handler registered for ${spec.componentName}`,
            )
          }
        })

        let anyPgStream =
          storedSpecs->Array.some(spec =>
            QueryDbBackend.postgresStreamRegistry->Set.has(spec.componentName)
          )
        buildLambda(
          ~parent,
          ~handlerOutputs,
          ~packageDirs,
          ~channelSpecs=storedSpecs->Array.map(({channelSpec}) => channelSpec),
          ~feedQueue,
          ~pgStreamConfig=anyPgStream ? eventsApiConfig.contents : None,
          ~memorySize=maxMemorySize,
          ~timeout=maxTimeout,
        )
      | None =>
        log.warn(~comp="StateViewSliceRuntime_Builder_Single", `finish: grandParent not set`)
      }
    }
    finished := true
  }
