module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

let log = ReventlessCore.Logger.fromEnv()

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type readModelInfo = {
  specModulePath: string,
  mappingsModulePath: string,
  queryDbTableName: Pulumi.Output.t<string>,
  /** B3.1: this read model's QueryDb is Postgres-backed — its HANDLER_CONFIG
      entry carries a `pgConnection` (admin-exempt read models stay DynamoDB,
      so the flag is per read model, not per Lambda). */
  pgBacked: bool,
}

let readModelInfos: dict<readModelInfo> = Dict.make()

// B3.3: the AppSync Events API a Postgres-backed stream read model publishes live
// updates to. Set once by `Platform.makePlatform` (monolithic mode) before the
// plugins build, so `finish` can add the APPSYNC_ENDPOINT env + appsync:EventPublish
// IAM to the projection Lambda. None → no live updates (no events API, or the
// platform runs without one).
type eventsApiConfig = {
  endpoint: Pulumi.Output.t<string>,
  apiArn: Pulumi.Output.t<string>,
}
let eventsApiConfig: ref<option<eventsApiConfig>> = ref(None)
let setEventsApiConfig = (cfg: eventsApiConfig) => eventsApiConfig := Some(cfg)

let registerReadModel = (
  ~readModelName,
  ~specModulePath,
  ~mappingsModulePath,
  ~queryDbTableName,
  ~pgBacked=false,
) =>
  readModelInfos->Dict.set(
    readModelName,
    {specModulePath, mappingsModulePath, queryDbTableName, pgBacked},
  )

type storedSpec = {
  componentName: string,
  /** The event collector's own resource name (`CustomersReadModel`), as opposed
      to `componentName` (its parent read model, `Customers`). Source of the
      `comp` baked into HANDLER_CONFIG — the deployed entry point annotates logs
      with it, so it must match the ReScript dispatch boundary's
      `EventCollector(<name>)` exactly (see
      docs/plans/entrypoint-dispatch-parity-and-latency-fields.md). */
  eventCollectorName: string,
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
      eventCollectorName,
      parentResource,
      sourceUrns,
      channelSpec: {channel, eventTopics, resources},
      memorySize,
      timeout,
    })
    ->ignore

    log.info(
      ~comp="EventCollectorRuntime_Builder_Single",
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
        let customOpts =
          opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

        // B3.0: Postgres-backed source logs have no DynamoDB stream — provision
        // the SQS feed queue the change-feed relay fans events into. Its ARN
        // doubles as the handlers' sourceUrn dispatch key (per-projection
        // filtering makes over-delivery a no-op).
        let feedQueue =
          EventLogBackend.isPostgres() || DcbBackend.isPostgres()
            ? Some(
                PgProjectionFeed.makeQueue(
                  ~name="AllReadModelsFeed",
                  ~scope="aws-rm-feed",
                  ~includeClassic=true,
                  ~includeDcb=true,
                  ~opts=customOpts,
                ),
              )
            : None
        let feedArnOutput = switch feedQueue {
        | Some(queue) => queue.arn
        | None => Pulumi.Output.make("")
        }

        // B3.1: Postgres-backed read models get a `pgConnection` in their handler
        // entry (per read model — admin-exempt ones stay DynamoDB in the same
        // Lambda). The Lambda itself goes in-VPC when any handler is pg-backed.
        let qdbSelection = QueryDbBackend.get()
        let anyPgBacked =
          readModelInfos->Dict.valuesToArray->Array.some(info => info.pgBacked)
        let pgConnectionFragment = switch (qdbSelection, anyPgBacked) {
        | (Some(sel), true) =>
          sel.connectionConfig->Pulumi.Output.apply(cc =>
            `,"pgConnection":${cc->PgConnection.connectionConfigToJson->JSON.stringify}`
          )
        | _ => Pulumi.Output.make("")
        }

        let handlerOutputs: array<Pulumi.Output.t<string>> = []
        let packageDirs: dict<string> = Dict.make()

        // Sort by componentName before serializing so the resulting
        // HANDLER_CONFIG.handlers array is stable across deploys. Without
        // this, the push order depends on platform-init order which can vary
        // between Node.js runs, producing pointless Lambda env-var "updates"
        // on every `pulumi up` even when nothing meaningful changed.
        let sortedSpecs =
          storedSpecs->Array.toSorted((a, b) => String.compare(a.componentName, b.componentName))

        sortedSpecs->Array.forEach(spec => {
          switch readModelInfos->Dict.get(spec.componentName) {
          | Some(info) =>
            // Collect unique user packages for the code asset
            let specPkg = Util_Bundle.extractPackageName(info.specModulePath)
            let mappingsPkg = Util_Bundle.extractPackageName(info.mappingsModulePath)
            packageDirs->Dict.set(specPkg, Util_Bundle.resolvePackageRoot(specPkg))
            packageDirs->Dict.set(mappingsPkg, Util_Bundle.resolvePackageRoot(mappingsPkg))

            let specModule =
              info.specModulePath->JSON.stringifyAny->Option.getOr(`""`)
            let mappingsModule =
              info.mappingsModulePath->JSON.stringifyAny->Option.getOr(`""`)

            let handlerPgFragment = info.pgBacked
              ? pgConnectionFragment
              : Pulumi.Output.make("")
            // B3.3: a subscription-enabled Postgres read model publishes live
            // updates from the projection Lambda — bake its AppSync Events channel
            // root (the plural LIST field name, same source as the DynamoDB
            // subscriptionInfraHook). Deploy-time resolved, so a plain string.
            let stateTopicFragment =
              info.pgBacked &&
              QueryDbBackend.postgresStreamRegistry->Set.has(spec.componentName) &&
              eventsApiConfig.contents->Option.isSome
                ? {
                    let topic =
                      ReventlessCore.Plugin_Helpers.queryFieldNamesRegistry
                      ->Dict.get(spec.componentName)
                      ->Option.map(qn => qn.listFieldName)
                      ->Option.getOr(spec.componentName)
                    `,"stateTopicName":${topic->JSON.Encode.string->JSON.stringify}`
                  }
                : ""
            // Log attribution baked at deploy time: this Lambda hosts every read
            // model, so the shell needs a per-handler `comp` to keep their log
            // lines separable, and a per-handler `plugin` because the shared
            // Lambda's own name carries no single plugin identity. Both are
            // resolved here — the registry LogPrefix consults is a deploy-time
            // structure, empty inside the Lambda.
            let attribution = Util_LogAttribution.fragments(
              ~comp=`EventCollector(${spec.eventCollectorName})`,
            )
            let handlerJson =
              Pulumi.Output.all4((
                info.queryDbTableName,
                spec.sourceUrns,
                feedArnOutput,
                handlerPgFragment,
              ))
              ->Pulumi.Output.apply(((tableName, urns, feedArn, pgFragment)) => {
                // No stream resource (Postgres-backed source) → dispatch on the
                // feed queue's ARN instead of a stream URN.
                let sourceUrn = urns->Array.get(0)->Option.getOr(feedArn)
                `{"specModule":${specModule},"mappingsModule":${mappingsModule},"queryDbTableName":"${tableName}","sourceUrn":"${sourceUrn}"${attribution}${pgFragment}${stateTopicFragment}}`
              })
            let _ = handlerOutputs->Array.push(handlerJson)
          | None =>
            log.warn(
              ~comp="EventCollectorRuntime_Builder_Single",
              `no handler registered for ${spec.componentName}`,
            )
          }
        })

        let handlerConfigOutput =
          Pulumi.Output.all(handlerOutputs)
          ->Pulumi.Output.apply(handlers => {
            let json = `{"handlers":[${handlers->Array.join(",")}]}`
            Util_LambdaEnvBudget.check(~lambdaName="AllReadModels", ~handlerConfigJson=json)
            json
          })

        let envVars: dict<Pulumi.Input.t<string>> = Dict.make()
        envVars->Dict.set("HANDLER_CONFIG", handlerConfigOutput->Pulumi.Output.asInput)

        // B3.3: when any Postgres-backed read model is subscription-enabled, the
        // projection Lambda publishes live updates to the AppSync Events API —
        // give it the endpoint (env) and appsync:EventPublish (IAM, below).
        let anyPgStream =
          readModelInfos
          ->Dict.keysToArray
          ->Array.some(rmName =>
            (readModelInfos->Dict.get(rmName)->Option.mapOr(false, i => i.pgBacked)) &&
              QueryDbBackend.postgresStreamRegistry->Set.has(rmName)
          )
        let pgStreamConfig = anyPgStream ? eventsApiConfig.contents : None
        switch pgStreamConfig {
        | Some(cfg) => envVars->Dict.set("APPSYNC_ENDPOINT", cfg.endpoint->Pulumi.Output.asInput)
        | None => ()
        }

        let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
          ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/ReadModelEntryPoint.mjs",
          ~packageDirs,
        )

        // Postgres-backed read models → the projection Lambda writes to RDS, so
        // it must land in-VPC on the DB-access security group + private subnets.
        let vpcConfig = switch (qdbSelection, anyPgBacked) {
        | (Some(sel), true) =>
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
        | _ => None
        }

        let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
          ~name="AllReadModels",
          ~unitKind=ReventlessCore.Monitoring.EventCollector,
          ~componentKind=ReventlessCore.ComponentType.EventCollector,
          ~code,
          ~sourceCodeHash,
          ~envVars,
          ~memorySize=maxMemorySize,
          ~timeout=maxTimeout,
          ~vpcConfig=?vpcConfig,
          ~opts,
        )

        // Grant the Postgres-backed projection Lambda read access to the
        // RDS-managed master secret so PgRuntime can resolve the DB password.
        switch (qdbSelection, anyPgBacked) {
        | (Some(sel), true) =>
          let _ = sel.connectionConfig->Pulumi.Output.apply(cc => {
            open PulumiAws.PolicyDocument
            PulumiAws.IAM.RolePolicy.make(
              ~name="AllReadModels-pgSecret",
              ~args={
                policy: PulumiAws.PolicyDocument.make(
                  ~id="AllReadModels-pgSecretPolicy",
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
        | _ => ()
        }

        // B3.3: grant the projection Lambda appsync:EventPublish on the events API
        // so a Postgres-backed stream read model can push live-update descriptors.
        switch pgStreamConfig {
        | Some(cfg) =>
          let _ = cfg.apiArn->Pulumi.Output.apply(apiArn => {
            open PulumiAws.PolicyDocument
            PulumiAws.IAM.RolePolicy.make(
              ~name="AllReadModels-appsyncPublish",
              ~args={
                policy: PulumiAws.PolicyDocument.make(
                  ~id="AllReadModels-appsyncPublishPolicy",
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

        let channelSpecs = storedSpecs->Array.map(({channelSpec}) => channelSpec)
        let _connectResources = EventCollectorChannel.connect(
          ~name="AllReadModels",
          ~channelSpecs,
          ~runtime,
          ~opts,
        )

        // B3.0: wire the Postgres feed queue into the Lambda (ESM + receive IAM).
        switch feedQueue {
        | Some(queue) =>
          PgProjectionFeed.connect(
            ~name="AllReadModelsFeed",
            ~queue,
            ~lambda=runtime.parts.lambda,
            ~lambdaRole=runtime.parts.lambdaRole,
            ~opts=customOpts,
          )
        | None => ()
        }
      | None =>
        log.warn(
          ~comp="EventCollectorRuntime_Builder_Single",
          `finish: grandParent not set`,
        )
      }
    }
    finished := true
  }
