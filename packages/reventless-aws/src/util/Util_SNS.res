let service = "SNS"

let toResource: PulumiAws.SNS.Topic.t => ReventlessSpec.Adapter.resource = ({id, name, arn}) => {
  ReventlessSpec.Adapter.service: name->Pulumi.Output.apply(_ => service),
  name,
  id,
  urn: arn,
  info: name->Pulumi.Output.apply(_ => ""),
}

let findUnwrappedResource = resources =>
  resources->Reventless.Util.Adapter.findUnwrappedResource(service)
