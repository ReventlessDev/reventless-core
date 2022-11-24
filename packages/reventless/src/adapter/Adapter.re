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

let unwrappedOutputToResource: t(unwrappedResource) => resource =
  unwrappedResource =>
    resource(
      ~service=unwrappedResource->apply(r => r##service),
      ~name=unwrappedResource->apply(r => r##name),
      ~id=unwrappedResource->apply(r => r##id),
      ~urn=unwrappedResource->apply(r => r##urn),
      ~info=unwrappedResource->apply(r => r##info),
    );
