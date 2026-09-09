type runtimeParts = {
  lambda: Pulumi.Output.t<PulumiAws.Lambda.Function.t>,
  lambdaRole: PulumiAws.IAM.Role.t,
}

let findResource = resources =>
  resources->ReventlessCore.Util.Adapter.findResource(AWS.Lambda.service)

let toResource = (
  ~tags=?,
  {id, name, arn}: PulumiAws.Lambda.Function.t,
): ReventlessInfra.Adapter.resource =>
  ReventlessInfra.Adapter.make(
    ~name,
    ~id,
    ~urn=arn,
    ~service=name->Pulumi.Output.apply(_ => AWS.Lambda.service),
    ~resourceType="aws:lambda:Function"->Pulumi.Output.make,
    ~tags?,
  )

let fromResource = ({id, name}: ReventlessInfra.Adapter.resource) => {
  name->Pulumi.Output.apply(name =>
    PulumiAws.Lambda.Function.get(~name, ~id=id->Pulumi.Output.asInput)
  )
}

let fromOutput = (output: Pulumi.Output.t<PulumiAws.Lambda.Function.t>) => {
  PulumiAws.Lambda.Function.arn: output->Pulumi.Output.flatMap(({arn}) => arn),
  id: output->Pulumi.Output.flatMap(({id}) => id),
  name: output->Pulumi.Output.flatMap(({name}) => name),
  invokeArn: output->Pulumi.Output.flatMap(({invokeArn}) => invokeArn),
  lastModified: output->Pulumi.Output.flatMap(({lastModified}) => lastModified),
}

/** Resolves once the function's update has actually landed — the barrier a
    deploy-time handshake needs before it may publish to that function.

    It must depend on `lastModified`. The identifiers (`arn`, `id`, `name`,
    `invokeArn`) are equal before and after a code update, so the engine resolves
    them from existing state and a gate built on one of them opens while the
    update is still in flight — measurably, about a second before it even starts.
    `sourceCodeHash` is no better: it is also an input, so it can be known in
    advance for the same reason. */
let updateLanded = (lambda: Pulumi.Output.t<PulumiAws.Lambda.Function.t>): Pulumi.Output.t<unit> =>
  lambda->Pulumi.Output.flatMap(({lastModified}) => lastModified)->Pulumi.Output.apply(_ => ())

let functionToResource = (
  ~tags=?,
  {id, name, arn}: PulumiAws.Lambda.Function.t,
): ReventlessInfra.Adapter.resource =>
  ReventlessInfra.Adapter.make(
    ~name,
    ~id,
    ~urn=arn,
    ~service=name->Pulumi.Output.apply(_ => AWS.Lambda.service),
    ~resourceType="aws:lambda:Function"->Pulumi.Output.make,
    ~tags?,
  )
