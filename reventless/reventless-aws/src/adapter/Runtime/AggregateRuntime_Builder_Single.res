module CommandTopicChannel = CommandTopicChannel.SQS_Sync
module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

type context = PulumiAws.Lambda.context
type runtimeParts = Util.Lambda.runtimeParts

type aggregateInfo = {
  specModulePath: string,
  behaviorModulePath: string,
  eventLogTableName: Pulumi.Output.t<string>,
}

let aggregateInfos: dict<aggregateInfo> = Dict.make()

let registerAggregate = (
  ~aggregateName,
  ~specModulePath,
  ~behaviorModulePath,
  ~eventLogTableName,
) =>
  aggregateInfos->Dict.set(
    aggregateName,
    {specModulePath, behaviorModulePath, eventLogTableName},
  )

// Plugin RM table name for the resolver-level plugin status gate (Part 2.3 of
// the resolver plan). Set by the platform after Admin.construct returns; consumed
// inside `finish()` to inject the `PLUGIN_RM_TABLE_NAME` env var and attach a
// `dynamodb:Scan` IAM policy on the AllAggregates Lambda role. Left unset means
// the gate is disabled (AggregateEntryPoint.mjs falls through to the handler).
// The ARN is derived from the table name with region/account wildcards
// (`arn:aws:dynamodb:*:*:table/<name>`) — same pattern as
// `Platform_UIDefinitions_Lambda`.
let pluginRmTableName: ref<option<Pulumi.Output.t<string>>> = ref(None)

let setPluginReadModelTable = (~name: Pulumi.Output.t<string>) => {
  pluginRmTableName := Some(name)
}

type storedSpec = {
  aggregateName: string,
  aggregateResource: Pulumi.Resource.t,
  queueUrl: Pulumi.Output.t<string>,
  queueArn: Pulumi.Output.t<string>,
  connects: array<ReventlessCore.Runtime.connect<runtimeParts>>,
  eventCollectorChannelSpec: option<
    ReventlessCore.EventCollector_Adapter.channelSpec<
      EventCollectorChannel.callbackEvent,
      context,
      EventCollectorChannel.channelParts,
    >,
  >,
  memorySize: int,
  timeout: int,
}

let storedSpecs: dict<storedSpec> = Dict.make()

let getStoredSpec = (aggregateName, aggregateResource) =>
  storedSpecs
  ->Dict.get(aggregateName)
  ->Option.getOr({
    aggregateName,
    aggregateResource,
    queueUrl: ""->Pulumi.Output.make,
    queueArn: ""->Pulumi.Output.make,
    connects: [],
    eventCollectorChannelSpec: None,
    memorySize: 0,
    timeout: 0,
  })

let forCommandGenerator: ReventlessCore.Runtime.forComponent<
  ReventlessCore.CommandGenerator.effectEventHandler<context>,
  runtimeParts,
  ReventlessCore.CommandGenerator.component,
> = (
  ~handler as _,
  ~connect,
  ~memorySize=1024,
  ~timeout=30,
  commandGenerator,
) => {
  let resource = commandGenerator->ReventlessCore.Component.toPulumiResource
  switch resource.parent {
  | Some(aggregateResource) =>
    let aggregateName = aggregateResource.name->Option.getOr("Unnamed")
    let spec = getStoredSpec(aggregateName, aggregateResource)
    storedSpecs->Dict.set(aggregateName, {
      ...spec,
      connects: spec.connects->Array.concat([connect]),
      memorySize: Math.Int.max(spec.memorySize, memorySize),
      timeout: Math.Int.max(spec.timeout, timeout),
    })
  | None => ()
  }
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
  switch commandTopicResource.parent {
  | Some(aggregateResource) =>
    let aggregateName = aggregateResource.name->Option.getOr("Unnamed")
    // Extract the SQS queue from the channel parts
    let channel = commandTopic->ReventlessCore.CommandTopic_Adapter.channel
    let channelParts: Util.SQS.channelParts = Obj.magic(channel.parts)
    let queue = channelParts.queue

    let spec = getStoredSpec(aggregateName, aggregateResource)
    storedSpecs->Dict.set(aggregateName, {
      ...spec,
      queueUrl: queue.id,
      queueArn: queue.arn,
      connects: spec.connects->Array.concat([connect]),
      memorySize: Math.Int.max(spec.memorySize, memorySize),
      timeout: Math.Int.max(spec.timeout, timeout),
    })
  | None =>
    let name = commandTopicResource.name->Option.getOr("Unnamed")
    JsError.throwWithMessage(
      `forCommandTopic(single): commandTopic ${name} has no Aggregate parent`,
    )
  }
}

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
  switch eventCollectorResource.parent->Option.flatMap(parent => parent.parent) {
  | Some(aggregateResource) =>
    let aggregateName = aggregateResource.name->Option.getOr("Unnamed")
    let spec = getStoredSpec(aggregateName, aggregateResource)
    storedSpecs->Dict.set(aggregateName, {
      ...spec,
      eventCollectorChannelSpec: Some({channel, eventTopics, resources}),
      memorySize: Math.Int.max(spec.memorySize, memorySize),
      timeout: Math.Int.max(spec.timeout, timeout),
    })
  | None =>
    let name = eventCollectorResource.name->Option.getOr("Unnamed")
    JsError.throwWithMessage(
      `forEventCollector(single): eventCollector ${name} has no Aggregate parent`,
    )
  }
}

let finished = ref(false)

let finish = () =>
  if !finished.contents {
    let specs = storedSpecs->Dict.valuesToArray
    if specs->Array.length > 0 {
      let (parent, memorySize, timeout) = specs->Array.reduce((None, 0, 0), (
        (_, accMemorySize, accTimeout),
        {aggregateResource, memorySize, timeout},
      ) => {
        (
          aggregateResource.parent,
          Math.Int.max(accMemorySize, memorySize),
          Math.Int.max(accTimeout, timeout),
        )
      })
      switch parent {
      | Some(parent) =>
        let opts = {Pulumi.ComponentResource.parent: parent}

        // Build HANDLER_CONFIG as a single JSON env var.
        // Each handler's dynamic values (table name, queue URL/ARN) are Pulumi Outputs
        // that resolve at deploy time. Static values (module paths) are plain strings.
        let handlerOutputs: array<Pulumi.Output.t<string>> = []
        let packageDirs: dict<string> = Dict.make()

        specs->Array.forEach(spec => {
          switch aggregateInfos->Dict.get(spec.aggregateName) {
          | Some(info) =>
            // Collect unique user packages for the code asset
            let specPkg = Util_Bundle.extractPackageName(info.specModulePath)
            let behaviorPkg = Util_Bundle.extractPackageName(info.behaviorModulePath)
            packageDirs->Dict.set(specPkg, Util_Bundle.resolvePackageRoot(specPkg))
            packageDirs->Dict.set(behaviorPkg, Util_Bundle.resolvePackageRoot(behaviorPkg))

            // Combine the three Output values into a JSON object string
            let specModule =
              info.specModulePath->JSON.stringifyAny->Option.getOr(`""`)
            let behaviorModule =
              info.behaviorModulePath->JSON.stringifyAny->Option.getOr(`""`)

            let handlerJson =
              Pulumi.Output.all3((info.eventLogTableName, spec.queueUrl, spec.queueArn))
              ->Pulumi.Output.apply(((table, queueUrl, queueArn)) =>
                `{"specModule":${specModule},"behaviorModule":${behaviorModule},"eventLogTable":"${table}","queueUrl":"${queueUrl}","queueArn":"${queueArn}"}`
              )
            let _ = handlerOutputs->Array.push(handlerJson)
          | None =>
            Console.warn(
              `AggregateRuntime_Builder_Single: no handler registered for ${spec.aggregateName}`,
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
        switch pluginRmTableName.contents {
        | Some(tableName) =>
          envVars->Dict.set("PLUGIN_RM_TABLE_NAME", tableName->Pulumi.Output.asInput)
        | None => ()
        }

        // Build AssetArchive: static re-export + user packages
        let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
          ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateEntryPoint.mjs",
          ~packageDirs,
        )

        let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
          ~name="AllAggregates",
          ~code,
          ~sourceCodeHash,
          ~envVars,
          ~memorySize,
          ~timeout,
          ~opts,
        )

        // Grant the AllAggregates Lambda dynamodb:Scan on the Plugin RM table so
        // the in-Lambda plugin status gate (AggregateEntryPoint.mjs::checkPluginStatus)
        // can read plugin status at command-dispatch time. Skipped if the platform
        // didn't register a Plugin RM table — gate is then a no-op. ARN is built
        // from the table name with region/account wildcards (mirrors the pattern
        // in Platform_UIDefinitions_Lambda).
        switch pluginRmTableName.contents {
        | Some(tableName) =>
          let _ =
            (tableName, runtime.parts.lambdaRole.id)
            ->Pulumi.Output.all2
            ->Pulumi.Output.apply(((name, roleId)) => {
              open PulumiAws.PolicyDocument
              let _ = PulumiAws.IAM.RolePolicy.make(
                ~name="AllAggregatesPluginRmScan",
                ~args={
                  PulumiAws.IAM.RolePolicy.policy: PulumiAws.PolicyDocument.make(
                    ~id="AllAggregatesPluginRmScanPolicy",
                    ~statements=[
                      {
                        sid: "AllowScanPluginRm",
                        effect: Allow,
                        actions: Actions(["dynamodb:Scan"]),
                        resources: Resource(`arn:aws:dynamodb:*:*:table/${name}`),
                      },
                    ],
                  )
                  ->PulumiAws.PolicyDocument.toJsonString
                  ->Pulumi.Input.make,
                  role: roleId->Pulumi.Input.make,
                },
              )
            })
        | None => ()
        }

        // Run all connect functions (IAM policies, event source mappings)
        specs->Array.forEach(({connects}) => {
          connects->Array.forEach(connect => connect(~runtime))
        })

        // Connect EventCollector channels
        let channelSpecs =
          specs
          ->Array.map(({eventCollectorChannelSpec}) => eventCollectorChannelSpec)
          ->Array.keepSome
        let _connectResources = EventCollectorChannel.connect(
          ~name="AllAggregates",
          ~channelSpecs,
          ~runtime,
          ~opts,
        )
      | None => ()
      }
    }
    finished := true
  }
