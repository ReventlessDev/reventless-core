type runtimeParts = {
  lambda: Pulumi.Output.t<PulumiAws.Lambda.CallbackFunction.t>,
  lambdaRole: PulumiAws.IAM.Role.t,
}

let findResource = resources => resources->ReventlessCore.Util.Adapter.findResource(AWS.Lambda.service)

let toResource: PulumiAws.Lambda.CallbackFunction.t => ReventlessInfra.Adapter.resource = ({
  id,
  name,
  arn,
}) => {
  ReventlessInfra.Adapter.service: name->Pulumi.Output.apply(_ => AWS.Lambda.service),
  name,
  id,
  urn: arn,
  info: name->Pulumi.Output.apply(_ => ""),
}

let fromResource = ({id, name}: ReventlessInfra.Adapter.resource) => {
  name->Pulumi.Output.apply(name =>
    PulumiAws.Lambda.CallbackFunction.get(~name, ~id=id->Pulumi.Output.asInput)
  )
}

let fromOutput = (output: Pulumi.Output.t<PulumiAws.Lambda.CallbackFunction.t>) => {
  PulumiAws.Lambda.CallbackFunction.arn: output->Pulumi.Output.flatMap(({arn}) => arn),
  id: output->Pulumi.Output.flatMap(({id}) => id),
  name: output->Pulumi.Output.flatMap(({name}) => name),
}
