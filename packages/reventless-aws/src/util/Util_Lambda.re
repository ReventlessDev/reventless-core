let service = "Lambda";

let toResource = (lambda: PulumiAws.Lambda.CallbackFunction.t) =>
  Reventless.Adapter.resource(
    ~service,
    ~name=lambda##id,
    ~id=lambda##id,
    ~urn=lambda##arn,
    ~info=lambda##id->Pulumi.Output.apply(_ => ""),
  );

let outputToResource =
    (lambda: Pulumi.Output.t(PulumiAws.Lambda.CallbackFunction.t)) =>
  Reventless.Adapter.resource(
    ~service,
    ~name=lambda->Pulumi.Output.flatMap(lambda => lambda##id),
    ~id=lambda->Pulumi.Output.flatMap(lambda => lambda##id),
    ~urn=lambda->Pulumi.Output.flatMap(lambda => lambda##arn),
    ~info=lambda->Pulumi.Output.apply(_ => ""),
  );
