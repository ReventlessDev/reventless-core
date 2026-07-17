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

// Legacy CallbackFunction path — retained for module type compatibility.
// Not called at runtime; all Lambda deployments now use makeFromCodeAsset.
// Can be removed once the module type no longer requires environmentMaker.
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

  let lambdaRole = IAM.Role.makeWithDefaultPolicy(
    ~name,
    ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
    ~opts?,
  )

  let tags = AWS.Tags.make(~name, ReventlessCore.CommandTopic.componentType)
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
  // This legacy path is only retained for module type compatibility.
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
      group, so it only takes effect when `~logRetentionDays` is also set. */
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

  let lambdaRole = IAM.Role.makeWithDefaultPolicy(
    ~name,
    ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
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

  let variables = Dict.fromArray([
    ("Environment", Pulumi.Pulumi.getStackName()->Pulumi.Input.make),
  ])
  envVars->Dict.forEachWithKey((value, key) => {
    variables->Dict.set(key, value)
  })
  additionalEnvVars->Dict.forEachWithKey((value, key) => {
    variables->Dict.set(key, value)
  })

  // ESM self-containment (Option C): every code archive built by
  // Util_Bundle.buildCodeArchive ships register-hook.mjs + layer-resolver.mjs at
  // /var/task. --import registers the resolve hook so the ESM entry point (and the
  // user spec/behavior modules it dynamically imports) can resolve bare specifiers
  // — @reventlessdev/*, effect, sury from the layer, @aws-sdk/* from the runtime —
  // that ESM `import` would otherwise not find outside /var/task. Framework
  // invariant: set last so it wins over any caller-supplied value.
  variables->Dict.set("NODE_OPTIONS", Util_Bundle.esmLoaderNodeOptions->Pulumi.Input.make)
  variables->Dict.set("ESM_FALLBACK_DIRS", Util_Bundle.esmFallbackDirs->Pulumi.Input.make)

  let tags = AWS.Tags.make(~name, ReventlessCore.CommandTopic.componentType)
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
    },
    ~opts?,
  )

  // Optional CloudWatch log-group with explicit retention. When not set, Lambda
  // auto-creates a log group with no retention (logs accumulate indefinitely).
  logRetentionDays->Option.forEach(days => {
    let logGroup = Cloudwatch.LogGroup.make(
      ~name=`${name}LogGroup`,
      ~args={
        name: `/aws/lambda/${name}`->Pulumi.Input.make,
        retentionInDays: days->Pulumi.Input.make,
      },
      ~opts?,
    )

    // DCB command-handler Lambdas: extract the provider-neutral metric lines
    // emitted by StateChangeSlice_Callback (`{reventlessMetric, slice, value}`)
    // into CloudWatch metrics. Attached to the managed log group above so there
    // is no race against Lambda's lazy auto-created group. Namespace/dimension
    // are CloudWatch-specific and live here, not in core (provider-neutral).
    if dcbMetrics {
      ["AppendRetry", "AppendConflict"]->Array.forEach(metricName => {
        let _ = Cloudwatch.LogMetricFilter.make(
          ~name=`${name}${metricName}Filter`,
          ~args={
            pattern: `{ $.reventlessMetric = "${metricName}" }`->Pulumi.Input.make,
            logGroupName: logGroup.name->Pulumi.Output.asInput,
            metricTransformation: ({
              name: metricName->Pulumi.Input.make,
              namespace: "Reventless/DCB"->Pulumi.Input.make,
              value: "$.value"->Pulumi.Input.make,
              defaultValue: "0"->Pulumi.Input.make,
              unit: "Count"->Pulumi.Input.make,
              dimensions: Dict.fromArray([("slice", "$.slice")])->Pulumi.Input.make,
            }: Cloudwatch.LogMetricFilter.metricTransformation)->Pulumi.Input.make,
          },
          ~opts?,
        )
      })
    }
  })

  let lambdaResource = lambda->Util.Lambda.functionToResource(~tags=tags->Pulumi.Output.fromInput)

  // Announce the provisioned execution unit to the Monitoring registry. No-op
  // unless a deploy program registered a backend via Monitoring.use — see
  // docs/plans/monitoring-hook-seam.md.
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

let extractCorrelationId = (event: event) =>
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
  ->Option.flatMap(meta => meta->Dict.get("correlationId"))
  ->Option.flatMap(JSON.Decode.string)

external asEventHandler: 'a => ReventlessCore.Runtime.eventHandler<event, context, 'result> =
  "%identity"
external asEffectHandler: 'a => ReventlessCore.Runtime.effectHandler<
  event,
  context,
  'result,
  'error,
> = "%identity"
