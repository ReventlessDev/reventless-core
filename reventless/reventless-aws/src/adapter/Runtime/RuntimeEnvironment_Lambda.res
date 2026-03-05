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

let groupBySource = (event: event) => {
  let dict: dict<event> = Dict.make()
  event.records->Array.forEach(record => {
    let eventSourceArn = record.eventSourceARN
    let currentEvent = dict->Dict.get(eventSourceArn)->Option.getOr({records: []})
    dict->Dict.set(eventSourceArn, {records: currentEvent.records->Array.concat([record])})
  })
  dict
}

external asEventHandler: 'a => ReventlessCore.Runtime.eventHandler<event, context, 'result> =
  "%identity"
external asEffectHandler: 'a => ReventlessCore.Runtime.effectHandler<event, context, 'result, 'error> =
  "%identity"

let logger = ReventlessCore.Runtime.defaultLogger
