let toResource: PulumiAws.SQS_Queue.t => ReventlessInfra.Adapter.resource = ({id, name, arn}) =>
  ReventlessInfra.Adapter.make(
    ~name,
    ~id,
    ~urn=arn,
    ~service=name->Pulumi.Output.apply(_ => AWS.SQS_FIFO.service),
    ~resourceType="aws:sqs:Queue"->Pulumi.Output.make,
  )

let fromResource = ({id, name}: ReventlessInfra.Adapter.resource) => {
  name->Pulumi.Output.apply(name => PulumiAws.SQS.Queue.get(~name, ~id=id->Pulumi.Output.asInput))
}

let findResource = resources =>
  resources->ReventlessCore.Util.Adapter.findResource(AWS.SQS_FIFO.service)
