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

let toResource: straightResource => resource =
  straightResource =>
    resource(
      ~service=straightResource##service->Obj.magic,
      ~name=straightResource##name->Obj.magic,
      ~id=straightResource##id->Obj.magic,
      ~urn=straightResource##urn->Obj.magic,
      ~info=straightResource##info->Obj.magic,
    );

let stackRefResourceToResource = stackRefResource =>
  stackRefResource
  ->Obj.magic // StackReference outputs are not wrapped in Pulumi.Outputs !
  ->toResource;
