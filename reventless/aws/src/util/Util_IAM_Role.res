let findResource = resources => resources->ReventlessCore.Util.Adapter.findResource(AWS.IAM.service)

let toResource: PulumiAws.IAM.Role.t => ReventlessInfra.Adapter.resource = ({id, name, arn}) =>
  ReventlessInfra.Adapter.make(
    ~name,
    ~id,
    ~urn=arn,
    ~service=name->Pulumi.Output.apply(_ => AWS.IAM.service),
    ~resourceType="aws:iam:Role"->Pulumi.Output.make,
  )

let fromResource = ({id, name}: ReventlessInfra.Adapter.resource) => {
  name->Pulumi.Output.apply(name => PulumiAws.IAM.Role.get(~name, ~id=id->Pulumi.Output.asInput))
}
