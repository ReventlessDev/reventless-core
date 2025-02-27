type context = PulumiAws.Lambda.context

let make: Reventless.Runtime.environmentMaker<'event, context, 'result> = (
  ~name,
  ~handler,
  ~opts=?,
) => {
  let opts =
    opts->Belt.Option.map(Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions)

  let lambdaResource =
    handler
    ->Pulumi.Output.apply(handler =>
      PulumiAws.Lambda.CallbackFunction.make(
        ~name,
        ~args=PulumiAws.Lambda.CallbackFunction.Args.make(
          ~callback=handler,
          ~policies=PulumiAws.Lambda.Policy.defaultPolicies,
          ~memorySize=1024->Pulumi.Input.make,
          ~timeout=30->Pulumi.Input.make,
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
