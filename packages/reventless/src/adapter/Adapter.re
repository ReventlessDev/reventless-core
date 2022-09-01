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

type unwrappedResource = {
  .
  "name": string,
  "id": string,
  "urn": string,
  "info": string,
  "service": string,
};

let unwrappedOutputToResource: Pulumi.Output.t(unwrappedResource) => resource =
  unwrappedResource =>
    resource(
      ~service=unwrappedResource->Pulumi.Output.apply(r => r##service),
      ~name=unwrappedResource->Pulumi.Output.apply(r => r##name),
      ~id=unwrappedResource->Pulumi.Output.apply(r => r##id),
      ~urn=unwrappedResource->Pulumi.Output.apply(r => r##urn),
      ~info=unwrappedResource->Pulumi.Output.apply(r => r##info),
    );
