let findResource = resources => resources->Reventless.Util.Adapter.findResource(AWS.IAM.service)

let toResource: PulumiAws.IAM.Role.t => ReventlessSpec.Adapter.resource = ({
  id,
  name,
  arn,
}) => {
  ReventlessSpec.Adapter.service: name->Pulumi.Output.apply(_ => AWS.IAM.service),
  name,
  id,
  urn: arn,
  info: name->Pulumi.Output.apply(_ => "")
}

let fromResource = ({id, name}: ReventlessSpec.Adapter.resource) => {
  name->Pulumi.Output.apply(name => PulumiAws.IAM.Role.get(~name, ~id=id->Pulumi.Output.asInput))
}