let service = "Lambda"

let findResource = resources => resources->Reventless.Util.Adapter.findResource(service)

let toResource: PulumiAws.Lambda.CallbackFunction.t => ReventlessSpec.Adapter.resource = ({
  id,
  name,
  arn,
}) => {
  ReventlessSpec.Adapter.service: name->Pulumi.Output.apply(_ => service),
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
