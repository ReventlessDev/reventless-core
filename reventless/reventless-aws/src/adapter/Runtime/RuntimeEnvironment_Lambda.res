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
// Not called at runtime in bundled deployments. Will be removed in Step 6
// (Unify Lambda Function Type).
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
  ~code: Pulumi.Archive.t,
  ~sourceCodeHash: string,
  ~envVars: dict<Pulumi.Input.t<string>>=?,
  ~memorySize: int=?,
  ~timeout: int=?,
  ~opts: Pulumi.ComponentResource.options=?,
) => ReventlessCore.Runtime.environment<parts> = (
  ~name,
  ~code,
  ~sourceCodeHash,
  ~envVars=Dict.make(),
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
      layers,
      tags,
      environment: ({Lambda.Function.variables: variables}: Lambda.Function.functionEnvironment)
        ->Pulumi.Input.make,
    },
    ~opts?,
  )

  {
    parts: {lambda: lambda->Pulumi.Output.make, lambdaRole},
    resources: [
      lambda->Util.Lambda.functionToResource(~tags=tags->Pulumi.Output.fromInput),
      Util_IAM_Role.toResource(lambdaRole),
    ],
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
