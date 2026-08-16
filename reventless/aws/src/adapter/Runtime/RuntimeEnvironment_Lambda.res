type event = PulumiAws.Lambda.CallbackFunction.event
type context = PulumiAws.Lambda.context
type parts = Util.Lambda.runtimeParts

// Generic env vars and IAM policies for all Lambdas created by makeFromCodeAsset.
// Consumers register additional config before deployPlugin triggers builder finish().
let additionalEnvVars: dict<Pulumi.Input.t<string>> = Dict.make()

type iamPolicy = {
  suffix: string,
  actions: string,
  resourceArn: Pulumi.Output.t<string>,
}
let additionalIamPolicies: array<iamPolicy> = []

// CallbackFunction path — the last serialized-closure Lambda builder on AWS.
//
// REACHABLE, despite most deployments going through makeFromCodeAsset. Three
// component builders instantiate ReventlessCore.EventCollectorRuntime_Builder_
// PerEventCollector.Make over this module — ForeignReadModel_Builder,
// SideEffectHandler_PerSideEffectHandler and Task_Builder_PerBucket — and that
// functor's forEventCollector calls `make` below. The live route is a Task whose
// spec returns `Task.sideEffects`: Task_Builder then constructs a
// SideEffectHandler, which provisions its collector Lambda here.
//
// A Lambda built this way is a serialized closure, and Pulumi's closure walker
// fails on Effect-TS — silently, so the function is simply never created and the
// deploy still reports success (see docs/plans/done/complete-bundled-migration.md,
// where an ordering-aws deploy came up four Lambdas short). Where it does
// serialize, it then resolves @aws-sdk against whatever the layer and the runtime
// each supply, carrying the cold-start SDK-skew failure compiled entry points
// were introduced to avoid. Converting these three builders to a compiled entry
// point is the fix; until then a side-effect-bearing Task is the exposed surface.
//
// `make` cannot simply be dropped: Runtime.Environment requires environmentMaker
// and the in-memory platform implements it for real (LocalRuntimeEnvironment
// registers the handler in a Deferred).
let make: ReventlessCore.Runtime.environmentMaker<'event, context, 'result, parts> = (
  ~name,
  ~handler,
  ~memorySize: int=1024,
  ~timeout: int=30,
  ~opts=?,
) => {
  open PulumiAws
  let opts =
    opts->Option.map(ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions)

  // The environmentMaker signature carries no component kind, so callers cannot
  // pass one through; attributed to the Platform rather than to an invented kind.
  let tags = AWS.Tags.make(~name, ~kind=ReventlessCore.ComponentType.Platform, ~role=Runtime, ~scope=Platform)

  let lambdaRole = IAM.Role.makeWithDefaultPolicy(
    ~name,
    ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
    ~tags=AWS.Tags.make(
      ~name,
      ~kind=ReventlessCore.ComponentType.Platform,
      ~role=Identity,
      ~scope=Platform,
    ),
    ~opts?,
  )
  let lambda =
    handler->Pulumi.Output.apply(handler =>
      Lambda.CallbackFunction.make(
        ~name,
        ~args=Lambda.CallbackFunction.Args.make(
          ~callback=handler,
          ~role=lambdaRole,
          ~memorySize=memorySize->Pulumi.Input.make,
          ~timeout=timeout->Pulumi.Input.make,
          ~tags,
        ),
        ~opts?,
      )
    )

  // Coerce CallbackFunction.t → Function.t (structurally compatible: both have arn, id, name).
  // The coercion goes away with the path itself, once the three PerEventCollector
  // builders above move to a compiled entry point.
  let lambdaAsFunction: Pulumi.Output.t<PulumiAws.Lambda.Function.t> = lambda->Obj.magic

  {
    parts: {lambda: lambdaAsFunction, lambdaRole},
    resources: [
      lambdaAsFunction
      ->Pulumi.Output.apply(lambda => lambda->Util.Lambda.toResource(~tags=tags->Pulumi.Output.fromInput))
      ->ReventlessCore.Adapter.outputToResource,
      Util_IAM_Role.toResource(lambdaRole),
    ],
  }
}

let makeFromCodeAsset: (
  ~name: string,
  /** The monitoring role this execution unit plays. Every call site passes its
      kind; `makeFromCodeAsset` announces the provisioned Lambda to the
      `Monitoring` registry (no-op unless an extension registered a backend). */
  ~unitKind: ReventlessCore.Monitoring.unitKind,
  /** The modelling kind of the component this Lambda runs, for resource
      attribution (`reventless:kind`). Distinct from `~unitKind`, which grades
      the unit by what its failure means — `CommandHandler` covers aggregates,
      state-change slices and extension points alike, so it cannot identify the
      owning component. Shared Lambdas that host several components of one kind
      (e.g. AllAggregates) pass that kind. */
  ~componentKind: ReventlessCore.ComponentType.t,
  ~code: Pulumi.Archive.t,
  ~sourceCodeHash: string,
  ~envVars: dict<Pulumi.Input.t<string>>=?,
  ~memorySize: int=?,
  ~timeout: int=?,
  ~reservedConcurrency: int=?,
  ~ephemeralStorageMb: int=?,
  ~logRetentionDays: int=?,
  /** Provision the DCB append-retry/conflict CloudWatch metric filters on this
      Lambda's log group (command-handler Lambdas only). Requires a managed log
      group, so it only takes effect when one is created — i.e. when
      `~logRetentionDays` is set or the stack tier manages its groups
      (`Util_LogRetention.managesLogGroup`). */
  ~dcbMetrics: bool=?,
  /** Place the Lambda in a VPC (needed to reach RDS/managed Postgres). When set,
      the execution role also gets the EC2 network-interface permissions AWS
      requires for VPC Lambdas. Build it from `PgConnection.{securityGroupId,
      subnetIds}`. */
  ~vpcConfig: Pulumi.Input.t<PulumiAws.Lambda.Function.vpcConfig>=?,
  ~opts: Pulumi.ComponentResource.options=?,
) => ReventlessCore.Runtime.environment<parts> = (
  ~name,
  ~unitKind,
  ~componentKind,
  ~code,
  ~sourceCodeHash,
  ~envVars=Dict.make(),
  ~memorySize: int=ReventlessCore.Runtime.CommandHandlerDefaults.memorySize,
  ~timeout: int=ReventlessCore.Runtime.CommandHandlerDefaults.timeout,
  ~reservedConcurrency=?,
  ~ephemeralStorageMb=?,
  ~logRetentionDays=?,
  ~dcbMetrics=false,
  ~vpcConfig=?,
  ~opts=?,
) => {
  open PulumiAws
  let opts =
    opts->Option.map(ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions)

  let stack = Pulumi.Pulumi.getStackName()

  // One attribution identity for every resource provisioned here: same owning
  // component and kind throughout, distinct piece roles — the function itself,
  // the execution identity it assumes, and its log group are three pieces of one
  // component, and an inventory needs to roll all three up to it.
  let tagsFor = (~resourceName, ~role) =>
    AWS.Tags.make(~name=resourceName, ~kind=componentKind, ~role, ~component=name)

  let lambdaRole = IAM.Role.makeWithDefaultPolicy(
    ~name,
    ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
    ~tags=tagsFor(~resourceName=name, ~role=Identity),
    ~opts?,
  )

  // VPC Lambdas must be able to manage ENIs in the target subnets. Attach the
  // standard EC2 network-interface permissions (resource "*", as ENIs have no
  // predictable ARN) whenever the function is VPC-placed.
  vpcConfig->Option.forEach(_ => {
    let _ = PulumiAws.IAM.RolePolicy.make(
      ~name=`${name}VpcAccess`,
      ~args={
        policy: PolicyDocument.make(
          ~id=`${name}VpcAccessPolicy`,
          ~statements=[
            {
              sid: "AllowVpcEni",
              effect: Allow,
              actions: Actions([
                "ec2:CreateNetworkInterface",
                "ec2:DescribeNetworkInterfaces",
                "ec2:DeleteNetworkInterface",
                "ec2:AssignPrivateIpAddresses",
                "ec2:UnassignPrivateIpAddresses",
              ]),
              resources: Resource("*"),
            },
          ],
        )
        ->PolicyDocument.toJsonString
        ->Pulumi.Input.make,
        role: lambdaRole.id->Pulumi.Output.asInput,
      },
    )
  })

  // Create additional IAM policies registered by consumers.
  additionalIamPolicies->Array.forEach(({suffix, actions, resourceArn}) => {
    let _ = resourceArn->Pulumi.Output.apply(arn => {
      let _ = PulumiAws.IAM.RolePolicy.make(
        ~name=`${name}${suffix}`,
        ~args={
          policy: PolicyDocument.make(
            ~id=`${name}${suffix}Policy`,
            ~statements=[
              {
                sid: `Allow${suffix}`,
                effect: Allow,
                actions: Action(actions),
                resources: Resource(arn),
              },
            ],
          )
          ->PolicyDocument.toJsonString
          ->Pulumi.Input.make,
          role: lambdaRole.id->Pulumi.Output.asInput,
        },
      )
    })
  })

  let layers =
    Lambda.reventlessLayerArn
    ->Option.map(arn => [arn->Pulumi.Input.make])
    ->Option.getOr([])
    ->Pulumi.Input.make

  let variables = Dict.fromArray([("Environment", stack->Pulumi.Input.make)])
  envVars->Dict.forEachWithKey((value, key) => {
    variables->Dict.set(key, value)
  })
  additionalEnvVars->Dict.forEachWithKey((value, key) => {
    variables->Dict.set(key, value)
  })

  // Default the logger's minimum level per environment tier when nothing already
  // pinned one (caller `envVars` or a consumer-registered `additionalEnvVars`
  // win) — for every Lambda, via the shared helper so the bespoke
  // `Lambda.Function.make` builders apply the identical policy.
  Util_LambdaLogging.applyLogLevelDefault(variables)

  // Same terms, same reason it is here rather than at each builder: the groups
  // exempt from owner scoping are decided by the deploy program, and the runtime
  // that stamps a command has no other way to learn them. Without it a runtime
  // concludes nobody is elevated and stamps an operator's on-behalf write with
  // the operator's own id.
  Util_OwnerScopeEnv.applyElevatedGroupsDefault(variables)

  // ESM self-containment (Option C): every code archive built by
  // Util_Bundle.buildCodeArchive ships register-hook.mjs + layer-resolver.mjs at
  // /var/task. --import registers the resolve hook so the ESM entry point (and the
  // user spec/behavior modules it dynamically imports) can resolve bare specifiers
  // — @reventlessdev/*, effect, sury from the layer, @aws-sdk/* from the runtime —
  // that ESM `import` would otherwise not find outside /var/task. Framework
  // invariant: set last so it wins over any caller-supplied value.
  variables->Dict.set("NODE_OPTIONS", Util_Bundle.esmLoaderNodeOptions->Pulumi.Input.make)
  variables->Dict.set("ESM_FALLBACK_DIRS", Util_Bundle.esmFallbackDirs->Pulumi.Input.make)

  // Runtime extension seam: the modules a cold start imports plus this runtime's
  // identity, so an out-of-tree extension can register the framework's runtime
  // callback hooks before the first request (see
  // ReventlessCore.RuntimeExtension). Emitted here rather than folded into
  // HANDLER_CONFIG for two reasons: every runtime builder already routes through
  // makeFromCodeAsset with the kind and name the seam needs, so no call site
  // changes; and HANDLER_CONFIG is already close to the 5120-byte
  // UpdateFunctionConfiguration limit. Absent entirely when nothing is
  // registered — an extension-free deployment gets the env it always had.
  if !ReventlessCore.RuntimeExtension.isEmpty() {
    let {ReventlessCore.ResourceAttribution.plugin: plugin, platform} =
      ReventlessCore.ResourceAttribution.current.contents
    let orNull = o => o->Option.mapOr(JSON.Null, s => JSON.String(s))
    let config = JSON.Object(
      Dict.fromArray([
        (
          "modules",
          JSON.Array(Util_Bundle.runtimeExtensionSpecifiers()->Array.map(s => JSON.String(s))),
        ),
        ("runtimeKind", JSON.String(componentKind->ReventlessCore.ComponentType.toString)),
        ("component", JSON.String(name)),
        ("plugin", plugin->orNull),
        ("platform", platform->orNull),
      ]),
    )
    variables->Dict.set("RUNTIME_EXTENSIONS", config->JSON.stringify->Pulumi.Input.make)
  }

  // Managed CloudWatch log group with explicit retention, created **before** the
  // function so the function can be told to write to it. That ordering is what
  // keeps the deploy the owner: a group created after its function races the
  // auto-create that the function's first invocation triggers, and losing that
  // race is permanent — the group persists, so every retry fails identically.
  // Runtimes with a heartbeat, a stream subscription or a schedule are invoked
  // within seconds of existing, so they lost it most reliably.
  //
  // Created when the caller pins `~logRetentionDays` (the app-developer opt-in)
  // OR the stack manages its groups — every stack by default, bar any named in
  // `unmanagedLogGroupStacks`. When neither holds, Lambda auto-creates an
  // unmanaged group with no retention, as before.
  let logGroup = Util_LambdaLogging.makeManagedLogGroup(
    ~name,
    ~retentionDaysOverride=?logRetentionDays,
    ~tags=tagsFor(~resourceName=`${name}LogGroup`, ~role=Logs),
    ~opts?,
    (),
  )

  let tags = tagsFor(~resourceName=name, ~role=Runtime)
  let lambda = Lambda.Function.make(
    ~name,
    ~args={
      handler: "index.handler"->Pulumi.Input.make,
      runtime: "nodejs22.x"->Pulumi.Input.make,
      code: code->Pulumi.Input.make,
      sourceCodeHash: sourceCodeHash->Pulumi.Input.make,
      role: lambdaRole.arn->Pulumi.Output.asInput,
      memorySize: memorySize->Pulumi.Input.make,
      timeout: timeout->Pulumi.Input.make,
      reservedConcurrentExecutions: ?reservedConcurrency->Option.map(Pulumi.Input.make),
      ephemeralStorage: ?ephemeralStorageMb->Option.map(mb =>
        ({size: mb->Pulumi.Input.make}: Lambda.Function.ephemeralStorage)->Pulumi.Input.make
      ),
      layers,
      tags,
      vpcConfig: ?vpcConfig,
      environment: ({Lambda.Function.variables: variables}: Lambda.Function.functionEnvironment)
        ->Pulumi.Input.make,
      // Points the function at the group above and, by reading its name output,
      // orders the function after it.
      loggingConfig: ?Util_LambdaLogging.loggingConfigFor(logGroup),
    },
    ~opts?,
  )

  // DCB command-handler Lambdas: extract the provider-neutral metric lines
  // emitted by StateChangeSlice_Callback (`{reventlessMetric, slice, value}`)
  // into CloudWatch metrics. Attached to the managed log group, which is the only
  // group the function ever writes to. Namespace/dimension are CloudWatch-specific
  // and live here, not in core (provider-neutral).
  if dcbMetrics {
    logGroup->Option.forEach(logGroup =>
      Util_DcbMetrics.metricNames->Array.forEach(metricName => {
        let _ = Cloudwatch.LogMetricFilter.make(
          ~name=`${name}${metricName}Filter`,
          ~args={
            pattern: Util_DcbMetrics.patternFor(metricName)->Pulumi.Input.make,
            logGroupName: logGroup.name->Pulumi.Output.asInput,
            metricTransformation: Util_DcbMetrics.transformationFor(metricName)->Pulumi.Input.make,
          },
          ~opts?,
        )
      })
    )
  }

  let lambdaResource = lambda->Util.Lambda.functionToResource(~tags=tags->Pulumi.Output.fromInput)

  // Announce the provisioned execution unit to the Monitoring registry. No-op
  // unless a deploy program registered a backend via Monitoring.use — see
  // docs/plans/done/monitoring-hook-seam.md.
  ReventlessCore.Monitoring.notify(~kind=unitKind, ~name, ~component=lambdaResource)

  {
    parts: {lambda: lambda->Pulumi.Output.make, lambdaRole},
    resources: [lambdaResource, Util_IAM_Role.toResource(lambdaRole)],
  }
}

let groupBySource = (event: event) => {
  let dict: dict<event> = Dict.make()
  event.records->Array.forEach(record => {
    let eventSourceArn = record.eventSourceARN
    let currentEvent = dict->Dict.get(eventSourceArn)->Option.getOr({records: []})
    dict->Dict.set(eventSourceArn, {records: currentEvent.records->Array.concat([record])})
  })
  dict
}

// SQS records carry a `body` string field not included in the minimal record type.
@get external recordBody: PulumiAws.Lambda.CallbackFunction.record => option<string> = "body"

// Read a single string field off the first SQS record's `meta` object.
let extractMetaField = (event: event, field) =>
  event.records
  ->Array.get(0)
  ->Option.flatMap(r =>
    r
    ->recordBody
    ->Option.flatMap(body => {
      try body->JSON.parseOrThrow->JSON.Decode.object catch {
      | _ => None
      }
    })
  )
  ->Option.flatMap(obj => obj->Dict.get("meta"))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(meta => meta->Dict.get(field))
  ->Option.flatMap(JSON.Decode.string)

let extractCorrelationId = (event: event) => event->extractMetaField("correlationId")
let extractCausationId = (event: event) => event->extractMetaField("causationId")

// SQS attributes ride on the record but are absent from the minimal record type
// (see the commented-out `attributes` field in SQS_Queue.res). Read them the same
// way `recordBody` reads `body`: as a typed getter over the untyped record.
type recordAttributes = {
  @as("SentTimestamp") sentTimestamp?: string,
  @as("ApproximateReceiveCount") approximateReceiveCount?: string,
}
@get
external recordAttributes: PulumiAws.Lambda.CallbackFunction.record => option<recordAttributes> =
  "attributes"

let firstRecordAttributes = (event: event) =>
  event.records->Array.get(0)->Option.flatMap(recordAttributes)

// Send time of the triggering message, ms since epoch. SQS stamps
// `SentTimestamp` server-side (not the producer's clock). DynamoDB-stream
// sources carry `ApproximateCreationDateTime` instead and are dispatched through
// the entry-point shells, so None here rather than a fabricated value.
let extractSentTimestamp = (event: event) =>
  event
  ->firstRecordAttributes
  ->Option.flatMap(attrs => attrs.sentTimestamp)
  ->Option.flatMap(Float.fromString)

// Delivery attempt, 1 on first delivery.
let extractRetryCount = (event: event) =>
  event
  ->firstRecordAttributes
  ->Option.flatMap(attrs => attrs.approximateReceiveCount)
  ->Option.flatMap(Int.fromString(_))

external asEventHandler: 'a => ReventlessCore.Runtime.eventHandler<event, context, 'result> =
  "%identity"
external asEffectHandler: 'a => ReventlessCore.Runtime.effectHandler<
  event,
  context,
  'result,
  'error,
> = "%identity"
