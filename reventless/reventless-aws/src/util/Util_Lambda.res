type runtimeParts = {
  lambda: Pulumi.Output.t<PulumiAws.Lambda.Function.t>,
  lambdaRole: PulumiAws.IAM.Role.t,
}

let findResource = resources => resources->ReventlessCore.Util.Adapter.findResource(AWS.Lambda.service)

let toResource: PulumiAws.Lambda.Function.t => ReventlessInfra.Adapter.resource = ({
  id,
  name,
  arn,
}) =>
  ReventlessInfra.Adapter.make(
    ~name,
    ~id,
    ~urn=arn,
    ~service=name->Pulumi.Output.apply(_ => AWS.Lambda.service),
    ~resourceType="aws:lambda:Function"->Pulumi.Output.make,
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
}

let functionToResource: PulumiAws.Lambda.Function.t => ReventlessInfra.Adapter.resource = ({
  id,
  name,
  arn,
}) =>
  ReventlessInfra.Adapter.make(
    ~name,
    ~id,
    ~urn=arn,
    ~service=name->Pulumi.Output.apply(_ => AWS.Lambda.service),
    ~resourceType="aws:lambda:Function"->Pulumi.Output.make,
  )
