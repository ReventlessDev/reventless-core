type context = PulumiAws.Lambda.context

let make: Reventless.Runtime.environmentMaker<'event, context, 'result> = (
  ~name,
  ~handler,
  ~memorySize: int=1024,
  ~timeout: int=30,
  ~policy1=?,
  ~policy2=?,
  ~opts=?,
) => {
  let opts =
    opts->Belt.Option.map(Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions)

  let lambdaResource =
    (handler, PulumiAws.Lambda.Policy.customPolicies(policy1, policy2))
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((handler, policies)) =>
      PulumiAws.Lambda.CallbackFunction.make(
        ~name,
        ~args=PulumiAws.Lambda.CallbackFunction.Args.make(
          ~callback=handler,
          ~policies,
          ~memorySize=memorySize->Pulumi.Input.make,
          ~timeout=timeout->Pulumi.Input.make,
          ~tags=AWS.tags(~name, Reventless.CommandTopic.componentType),
        ),
        ~opts?,
      )->Util_Lambda.toResource
    )
    ->Reventless.Adapter.outputToResource

  {
    resources: [lambdaResource],
  }
}
