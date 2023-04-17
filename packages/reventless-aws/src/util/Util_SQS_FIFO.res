let service = "SQS_FIFO"

let toResource = (queue: PulumiAws.SQS.Queue.t) =>
  Reventless.Adapter.resource(
    ~service=queue["name"]->Pulumi.Output.apply(_ => service),
    ~name=queue["name"],
    ~id=queue["id"],
    ~urn=queue["arn"],
    ~info=queue["name"]->Pulumi.Output.apply(_ => ""),
  )
