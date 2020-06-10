let toResource = (queue: PulumiAws.SQS.Queue.t) =>
  Adapter.resource(
    ~service="SQS",
    ~name=queue##name,
    ~id=queue##id,
    ~urn=queue##arn,
    ~info=queue##name->Pulumi.Output.apply(_ => ""),
  );