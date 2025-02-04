let service = "SNS"

let toRuntimeTopicOutput = ({name, id, arn}: PulumiAws.SNS.Topic.t) =>
  [name, id, arn]
  ->Pulumi.Output.all
  ->Pulumi.Output.apply(([name, id, arn]) => {
    Util_SNS_Runtime.id,
    name,
    arn,
  })

let toResource: PulumiAws.SNS.Topic.t => ReventlessSpec.Adapter.resource = ({id, name, arn}) => {
  ReventlessSpec.Adapter.service: name->Pulumi.Output.apply(_ => service),
  name,
  id,
  urn: arn,
  info: name->Pulumi.Output.apply(_ => ""),
}

let findUnwrappedResource = resources =>
  resources->Reventless.Util.Adapter.findUnwrappedResource(service)
