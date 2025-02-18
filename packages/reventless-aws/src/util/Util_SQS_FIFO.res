let service = "SQS_FIFO"

let toResource: PulumiAws.SQS_Queue.t => ReventlessSpec.Adapter.resource = ({id, name, arn}) => {
  ReventlessSpec.Adapter.service: name->Pulumi.Output.apply(_ => service),
  name,
  id,
  urn: arn,
  info: name->Pulumi.Output.apply(_ => ""),
}

let fromResource = ({urn, id, name}: ReventlessSpec.Adapter.resource) => {
  PulumiAws.SQS.Queue.name,
  id,
  arn: urn,
}

let findResource = resources => resources->Reventless.Util.Adapter.findResource(service)
