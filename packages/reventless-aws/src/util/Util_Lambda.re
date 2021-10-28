let service = "Lambda";

let toResource = (lambda: PulumiAws.Lambda.CallbackFunction.t) =>
  Reventless.Adapter.resource(
    ~service,
    ~name=lambda##name,
    ~id=lambda##id,
    ~urn=lambda##arn,
    ~info=lambda##name->Pulumi.Output.apply(_ => ""),
  );

let outputToResource =
    (lambda: Pulumi.Output.t(PulumiAws.Lambda.CallbackFunction.t)) =>
  Reventless.Adapter.resource(
    ~service,
    ~name=lambda->Pulumi.Output.flatMap(lambda => lambda##name),
    ~id=lambda->Pulumi.Output.flatMap(lambda => lambda##id),
    ~urn=lambda->Pulumi.Output.flatMap(lambda => lambda##arn),
    ~info=lambda->Pulumi.Output.apply(_ => ""),
  );
