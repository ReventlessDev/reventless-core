type t = Js.Dict.t(ReventlessSpec.Adapter.resource);

let tmpResources: t = Js.Dict.empty();

let resourcesFinalized = ref(false);

let (resources, resolveResources) = {
  let resolveResources = ref((. _d: t) => ());
  let resourcesOutput =
    Js.Promise.make((~resolve, ~reject as _) => resolveResources := resolve)
    ->Pulumi.Output.makeFromPromise;
  (resourcesOutput, resolveResources);
};

let createResourceName = (~adapter, ~name) => name ++ "." ++ adapter;

let get = (~adapter, ~name, resources) =>
  resources->Js.Dict.get(createResourceName(~adapter, ~name));

let filter = (~adapter, ~name, ~keep, resources) =>
  resources
  ->Js.Dict.entries
  ->Belt.Array.keepMap(((resourceName, resource)) =>
      resourceName->Js.String2.endsWith(createResourceName(~name, ~adapter))
      && keep(name)
        ? Some(resource) : None
    );

module Deploytime = {
  let finalize = () => {
    resolveResources^(. tmpResources);
    resourcesFinalized := true;
  };

  let set = (~adapter, ~name, ~resource) => {
    if (resourcesFinalized^) {
      Js.Exn.raiseError(
        {j|Resources already finalized! Tried to set resource: $adapter $name|j},
      );
    };
    let existingResourceO =
      tmpResources->Js.Dict.get(createResourceName(~adapter, ~name));
    switch (existingResourceO) {
    | Some(existingResource) =>
      let existing = existingResource->Js.Json.stringifyAny;
      let new_ = resource->Js.Json.stringifyAny;
      Js.Exn.raiseError(
        {j|Resource exists already: $adapter $name, existing resource: $existing, new resource: $new_|j},
      );
    | None => tmpResources->Js.Dict.set(name ++ "." ++ adapter, resource)
    };
  };

  let get = (~adapter, ~name) => tmpResources->get(~adapter, ~name);

  let getExn = (~adapter, ~name) =>
    switch (get(~adapter, ~name)) {
    | Some(resource) => resource
    | None =>
      let resources = resources->Pulumi.Output.get->Js.Dict.keys;
      Js.Exn.raiseError(
        {j|Resource doesn't exist: $adapter $name, resources: $resources|j},
      );
    };

  let filter = (~name, ~adapter, ~keep) => {
    tmpResources->filter(~adapter, ~name, ~keep);
  };
};

module Runtime = {
  let get = (~adapter, ~name) =>
    resources->Pulumi.Output.get->get(~adapter, ~name);

  let getExn = (~adapter, ~name) =>
    switch (get(~adapter, ~name)) {
    | Some(resource) => resource
    | None =>
      let resources = resources->Pulumi.Output.get->Js.Dict.keys;
      Js.Exn.raiseError(
        {j|Resource doesn't exist: $adapter $name, resources: $resources|j},
      );
    };

  let filter = (~name, ~adapter, ~keep) => {
    resources->Pulumi.Output.get->filter(~adapter, ~name, ~keep);
  };
};
