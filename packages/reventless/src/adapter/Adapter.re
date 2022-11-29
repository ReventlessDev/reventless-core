open ReventlessSpec.Adapter;
open Pulumi.Output;

[@bs.obj]
external resource:
  (
    ~service: t(string),
    ~name: t(string),
    ~id: t(string),
    ~urn: t(string),
    ~info: t(string)
  ) =>
  resource =
  "";

let outputToResource: t(resource) => resource =
  resourceOutput =>
    resource(
      ~id=resourceOutput->flatMap(r => r##id),
      ~name=resourceOutput->flatMap(r => r##name),
      ~urn=resourceOutput->flatMap(r => r##urn),
      ~info=resourceOutput->flatMap(r => r##info),
      ~service=resourceOutput->flatMap(r => r##service),
    );

let resourcesOutputToResource: t(array(resource)) => option(resource) =
  resourcesOutput =>
    try (
      resource(
        ~id=resourcesOutput->flatMap(r => r[0]##id),
        ~name=resourcesOutput->flatMap(r => r[0]##name),
        ~urn=resourcesOutput->flatMap(r => r[0]##urn),
        ~info=resourcesOutput->flatMap(r => r[0]##info),
        ~service=resourcesOutput->flatMap(r => r[0]##service),
      )
      ->Some
    ) {
    | _ => None
    };

type unwrappedResource = {
  .
  "name": string,
  "id": string,
  "urn": string,
  "info": string,
  "service": string,
};

let unwrappedToResource: unwrappedResource => resource =
  unwrappedResource =>
    resource(
      ~service=unwrappedResource##service->make,
      ~name=unwrappedResource##name->make,
      ~id=unwrappedResource##id->make,
      ~urn=unwrappedResource##urn->make,
      ~info=unwrappedResource##info->make,
    );

let unwrappedOutputToResource: t(unwrappedResource) => resource =
  unwrappedResource =>
    resource(
      ~service=unwrappedResource->apply(r => r##service),
      ~name=unwrappedResource->apply(r => r##name),
      ~id=unwrappedResource->apply(r => r##id),
      ~urn=unwrappedResource->apply(r => r##urn),
      ~info=unwrappedResource->apply(r => r##info),
    );

let logResource = r => {
  let _ = r##name->Pulumi.Output.apply(name => Js.log2("Resource: ", name));
  let _ = r##id->Pulumi.Output.apply(id => Js.log2("  id: ", id));
  let _ = r##urn->Pulumi.Output.apply(urn => Js.log2("  urn: ", urn));
  let _ =
    r##service
    ->Pulumi.Output.apply(service => Js.log2("  service: ", service));
  ();
};
