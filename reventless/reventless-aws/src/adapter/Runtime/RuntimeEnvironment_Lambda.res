type event = PulumiAws.Lambda.CallbackFunction.event
type context = PulumiAws.Lambda.context
type parts = Util.Lambda.runtimeParts

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

  let lambda =
    handler->Pulumi.Output.apply(handler =>
      Lambda.CallbackFunction.make(
        ~name,
        ~args=Lambda.CallbackFunction.Args.make(
          ~callback=handler,
          ~role=lambdaRole,
          ~memorySize=memorySize->Pulumi.Input.make,
          ~timeout=timeout->Pulumi.Input.make,
          ~tags=AWS.Tags.make(~name, ReventlessCore.CommandTopic.componentType),
        ),
        ~opts?,
      )
    )

  {
    parts: {lambda, lambdaRole},
    resources: [
      lambda
      ->Pulumi.Output.apply(lambda => lambda->Util.Lambda.toResource)
      ->ReventlessCore.Adapter.outputToResource,
      Util_IAM_Role.toResource(lambdaRole),
    ],
  }
}

let makeBundled: ReventlessCore.Runtime.bundledEnvironmentMaker<parts> = (
  ~name,
  ~handlerRef: ReventlessCore.Runtime.handlerRef,
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

  let code = Util_Bundle.bundleHandler(
    ~entryPoint=handlerRef.handlerModule,
    ~exportName=handlerRef.handlerExport,
  )

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

  let lambda = Lambda.Function.make(
    ~name,
    ~args={
      handler: "index.handler"->Pulumi.Input.make,
      runtime: "nodejs22.x"->Pulumi.Input.make,
      code: code->Pulumi.Input.make,
      role: lambdaRole.arn->Pulumi.Output.asInput,
      memorySize: memorySize->Pulumi.Input.make,
      timeout: timeout->Pulumi.Input.make,
      layers,
      tags: AWS.Tags.make(~name, ReventlessCore.CommandTopic.componentType),
      environment: ({Lambda.Function.variables: variables}: Lambda.Function.functionEnvironment)
        ->Pulumi.Input.make,
    },
    ~opts?,
  )

  let lambdaAsCallback: Pulumi.Output.t<Lambda.CallbackFunction.t> =
    lambda->Util.Lambda.functionToCallbackFunction->Pulumi.Output.make

  {
    parts: {lambda: lambdaAsCallback, lambdaRole},
    resources: [
      lambda->Util.Lambda.functionToResource,
      Util_IAM_Role.toResource(lambdaRole),
    ],
  }
}

let makeBundledFromEntryPoint: (
  ~name: string,
  ~entryPointCode: string,
  ~envVars: dict<Pulumi.Input.t<string>>=?,
  ~memorySize: int=?,
  ~timeout: int=?,
  ~opts: Pulumi.ComponentResource.options=?,
) => ReventlessCore.Runtime.environment<parts> = (
  ~name,
  ~entryPointCode,
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

  let code = Util_Bundle.bundleEntryPoint(entryPointCode)

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

  let lambda = Lambda.Function.make(
    ~name,
    ~args={
      handler: "index.handler"->Pulumi.Input.make,
      runtime: "nodejs22.x"->Pulumi.Input.make,
      code: code->Pulumi.Input.make,
      role: lambdaRole.arn->Pulumi.Output.asInput,
      memorySize: memorySize->Pulumi.Input.make,
      timeout: timeout->Pulumi.Input.make,
      layers,
      tags: AWS.Tags.make(~name, ReventlessCore.CommandTopic.componentType),
      environment: ({Lambda.Function.variables: variables}: Lambda.Function.functionEnvironment)
        ->Pulumi.Input.make,
    },
    ~opts?,
  )

  let lambdaAsCallback: Pulumi.Output.t<Lambda.CallbackFunction.t> =
    lambda->Util.Lambda.functionToCallbackFunction->Pulumi.Output.make

  {
    parts: {lambda: lambdaAsCallback, lambdaRole},
    resources: [
      lambda->Util.Lambda.functionToResource,
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
