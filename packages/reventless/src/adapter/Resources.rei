type t;

let resources: Pulumi.Output.t(t);

module Deploytime: {
  let set:
    (
      ~adapter: string,
      ~name: string,
      ~resource: ReventlessSpec.Adapter.resource
    ) =>
    unit;

  let finalize: unit => unit;

  let get:
    (~adapter: string, ~name: string) =>
    option(ReventlessSpec.Adapter.resource);

  let getExn:
    (~adapter: string, ~name: string) => ReventlessSpec.Adapter.resource;
};

module Runtime: {
  let get:
    (~adapter: string, ~name: string) =>
    option(ReventlessSpec.Adapter.resource);

  let getExn:
    (~adapter: string, ~name: string) => ReventlessSpec.Adapter.resource;

  let filter:
    (~name: string, ~adapter: string, ~keep: string => bool) =>
    array(ReventlessSpec.Adapter.resource);
};
