type context = PulumiAws.Lambda.context

let make: Reventless.Runtime.environmentMaker<'event, context, 'result> = (
  ~name,
  ~handler,
  ~memorySize: int=1024,
  ~timeout: int=30,
  ~opts=?,
) => {
  open PulumiAws
  let opts =
    opts->Belt.Option.map(Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions)

  let lambdaRole = IAM.Role.makeWithDefaultPolicy(~name=name++"Role", ~service="lambda.amazonaws.com"->Pulumi.Output.make) 

  let lambdaResource =
    (handler)
    ->Pulumi.Output.apply( handler =>
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
      )->Util_Lambda.toResource
    )
    ->Reventless.Adapter.outputToResource

  {
    resources: [lambdaResource, Util_IAM_Role.toResource(lambdaRole)],
  }
}
