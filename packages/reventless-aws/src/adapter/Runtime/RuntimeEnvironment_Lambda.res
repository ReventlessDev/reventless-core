type context = PulumiAws.Lambda.context
type parts = Util.Lambda.runtimeParts

let make: Reventless.Runtime.environmentMaker<'event, context, 'result, parts> = (
  ~name,
  ~handler,
  ~memorySize: int=1024,
  ~timeout: int=30,
  ~opts=?,
) => {
  open PulumiAws
  let opts =
    opts->Belt.Option.map(Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions)

  let lambdaRole = IAM.Role.makeWithDefaultPolicy(
    ~name=name ++ "Role",
    ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
    ~opts?,
  )

  let lambda =
    handler
    ->Pulumi.Output.apply(handler =>
      Lambda.CallbackFunction.make(
        ~name,
        ~args=Lambda.CallbackFunction.Args.make(
          ~callback=handler,
          ~role=lambdaRole,
          ~memorySize=memorySize->Pulumi.Input.make,
          ~timeout=timeout->Pulumi.Input.make,
          ~tags=AWS.Tags.make(~name, Reventless.CommandTopic.componentType),
        ),
        ~opts?,
      )
    )
    ->Util.Lambda.fromOutput

  {
    parts: {lambda, lambdaRole},
    resources: [lambda->Util.Lambda.toResource, Util_IAM_Role.toResource(lambdaRole)],
  }
}
