let toResource: PulumiAws.SQS_Queue.t => Reventless.Adapter.resource = ({id, name, arn}) => {
  Reventless.Adapter.service: name->Pulumi.Output.apply(_ => AWS.SQS_FIFO.service),
  name,
  id,
  urn: arn,
  info: name->Pulumi.Output.apply(_ => ""),
}

let fromResource = ({id, name}: Reventless.Adapter.resource) => {
  name->Pulumi.Output.apply(name => PulumiAws.SQS.Queue.get(~name, ~id=id->Pulumi.Output.asInput))
}

let findResource = resources =>
  resources->ReventlessCore.Util.Adapter.findResource(AWS.SQS_FIFO.service)
