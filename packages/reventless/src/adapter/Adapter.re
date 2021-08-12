open ReventlessSpec.Adapter;

[@bs.obj]
external resource:
  (
    ~service: string,
    ~name: Pulumi.Output.t(string),
    ~id: Pulumi.Output.t(string),
    ~urn: Pulumi.Output.t(string),
    ~info: Pulumi.Output.t(string)
  ) =>
  resource =
  "";

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
    ~service=straightResource##service,
    ~name=straightResource##name->Pulumi.Output.make,
    ~id=straightResource##id->Pulumi.Output.make,
    ~urn=straightResource##urn->Pulumi.Output.make,
    ~info=straightResource##info->Pulumi.Output.make,
  );
