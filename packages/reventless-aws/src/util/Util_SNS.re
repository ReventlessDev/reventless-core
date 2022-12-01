let service = "SNS";

let toResource = (topic: PulumiAws.SNS.Topic.t) =>
  Reventless.Adapter.resource(
    ~service=topic##name->Pulumi.Output.apply(_ => service),
    ~name=topic##name,
    ~id=topic##id,
    ~urn=topic##arn,
    ~info=topic##name->Pulumi.Output.apply(_ => ""),
  );

let findUnwrappedResource = resources =>
  resources->Reventless.Util.Adapter.findUnwrappedResource(service);
