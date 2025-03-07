let findResource = resources => resources->Reventless.Util.Adapter.findResource(AWS.Lambda.service)

let toResource: PulumiAws.Lambda.CallbackFunction.t => ReventlessSpec.Adapter.resource = ({
  id,
  name,
  arn,
}) => {
  ReventlessSpec.Adapter.service: name->Pulumi.Output.apply(_ => AWS.Lambda.service),
  name,
  id,
  urn: arn,
  info: name->Pulumi.Output.apply(_ => ""),
}

let fromResource = ({id, name}: ReventlessSpec.Adapter.resource) => {
  name->Pulumi.Output.apply(name =>
    PulumiAws.Lambda.CallbackFunction.get(~name, ~id=id->Pulumi.Output.asInput)
  )
}
