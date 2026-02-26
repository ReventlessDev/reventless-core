let findResource = resources => resources->ReventlessCore.Util.Adapter.findResource(AWS.IAM.service)

let toResource: PulumiAws.IAM.Role.t => Reventless.Adapter.resource = ({id, name, arn}) => {
  Reventless.Adapter.service: name->Pulumi.Output.apply(_ => AWS.IAM.service),
  name,
  id,
  urn: arn,
  info: name->Pulumi.Output.apply(_ => ""),
}

let fromResource = ({id, name}: Reventless.Adapter.resource) => {
  name->Pulumi.Output.apply(name => PulumiAws.IAM.Role.get(~name, ~id=id->Pulumi.Output.asInput))
}
