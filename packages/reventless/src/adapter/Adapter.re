open ReventlessSpec.Adapter;

[@bs.obj]
external resource:
  (
    ~service: Pulumi.Output.t(string),
    ~name: Pulumi.Output.t(string),
    ~id: Pulumi.Output.t(string),
    ~urn: Pulumi.Output.t(string),
    ~info: Pulumi.Output.t(string)
  ) =>
  resource =
  "";

let outputToResource = resourceOutput =>
  resource(
    ~id=resourceOutput->Pulumi.Output.flatMap(resource => resource##id),
    ~name=resourceOutput->Pulumi.Output.flatMap(resource => resource##name),
    ~urn=resourceOutput->Pulumi.Output.flatMap(resource => resource##urn),
    ~info=resourceOutput->Pulumi.Output.flatMap(resource => resource##info),
    ~service=
      resourceOutput->Pulumi.Output.flatMap(resource => resource##service),
  );

type straightResource = {
  .
  "name": string,
  "id": string,
  "urn": string,
  "info": string,
  "service": string,
};

let straightOutputToResource: Pulumi.Output.t(straightResource) => resource =
  straightResource =>
    resource(
      ~service=straightResource->Pulumi.Output.apply(r => r##service),
      ~name=straightResource->Pulumi.Output.apply(r => r##name),
      ~id=straightResource->Pulumi.Output.apply(r => r##id),
      ~urn=straightResource->Pulumi.Output.apply(r => r##urn),
      ~info=straightResource->Pulumi.Output.apply(r => r##info),
    );
