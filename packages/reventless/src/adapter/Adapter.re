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

let toResource = straightResource =>
  resource(
    ~service=straightResource##service->Pulumi.Output.make,
    ~name=straightResource##name->Pulumi.Output.make,
    ~id=straightResource##id->Pulumi.Output.make,
    ~urn=straightResource##urn->Pulumi.Output.make,
    ~info=straightResource##info->Pulumi.Output.make,
  );
