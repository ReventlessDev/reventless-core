let service = "Lambda";

let toResource = (lambda: PulumiAws.Lambda.CallbackFunction.t) =>
  Reventless.Adapter.resource(
    ~service=service->Pulumi.Output.make,
    ~name=lambda##id,
    ~id=lambda##id,
    ~urn=lambda##arn,
    ~info=""->Pulumi.Output.make,
  );

let outputToResource:
  Pulumi.Output.t(PulumiAws.Lambda.CallbackFunction.t) =>
  ReventlessSpec.Adapter.resource =
  lambdaOutput => {
    Reventless.Adapter.resource(
      ~service=service->Pulumi.Output.make,
      ~name=lambdaOutput->Pulumi.Output.flatMap(lambda => lambda##id),
      ~id=lambdaOutput->Pulumi.Output.flatMap(lambda => lambda##id),
      ~urn=lambdaOutput->Pulumi.Output.flatMap(lambda => lambda##arn),
      ~info=""->Pulumi.Output.make,
    );
  };
