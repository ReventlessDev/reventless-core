let service = "SNS_FIFO";

let toResource = (topic: PulumiAws.SNS.Topic.t) =>
  Reventless.Adapter.resource(
    ~service,
    ~name=topic##name,
    ~id=topic##id,
    ~urn=topic##arn,
    ~info=topic##name->Pulumi.Output.apply(_ => ""),
  );
