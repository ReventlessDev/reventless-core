let toResource: PulumiAws.SQS_Queue.t => ReventlessSpec.Adapter.resource = ({id, name, arn}) => {
  ReventlessSpec.Adapter.service: name->Pulumi.Output.apply(_ => AWS.SQS_FIFO.service),
  name,
  id,
  urn: arn,
  info: name->Pulumi.Output.apply(_ => "")
}

let fromResource = ({id, name}: ReventlessSpec.Adapter.resource) => {
  name->Pulumi.Output.apply(name => PulumiAws.SQS.Queue.get(~name, ~id=id->Pulumi.Output.asInput))
}

let findResource = resources =>
  resources->Reventless.Util.Adapter.findResource(AWS.SQS_FIFO.service)
