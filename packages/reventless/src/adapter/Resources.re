let resources: Js.Dict.t(ReventlessSpec.Adapter.resource) = Js.Dict.empty();

let resourceName = (~adapter, ~name) => name ++ "." ++ adapter;

let set = (~adapter, ~name, resource) =>
  resources
  ->Js.Dict.get(resourceName(~adapter, ~name))
  ->(
      fun
      | Some(existingResource) => {
          let existing = existingResource->Js.Json.stringifyAny;
          let new_ = resource->Js.Json.stringifyAny;
          Js.Exn.raiseError(
            {j|Resource exists already: $adapter $name, existing resource: $existing, new resource: $new_|j},
          );
        }
      | None => resources->Js.Dict.set(name ++ "." ++ adapter, resource)
    );

let get = (~adapter, ~name) =>
  resources->Js.Dict.get(resourceName(~adapter, ~name));

let getExn = (~adapter, ~name) =>
  get(~adapter, ~name)
  ->(
      fun
      | Some(resource) => resource
      | None => {
          let resources = resources->Js.Dict.keys;
          Js.Exn.raiseError(
            {j|Resource doesn't exist: $adapter $name, resources: $resources|j},
          );
        }
    );
