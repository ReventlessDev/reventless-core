let createResourceName = (~adapter, ~name) => name ++ "." ++ adapter;

let get = (~adapter, ~name, resources) =>
  resources->Js.Dict.get(createResourceName(~adapter, ~name));

let getExn = (~adapter, ~name, resources) =>
  resources
  ->get(~adapter, ~name)
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

let set = (~adapter, ~name, ~resource, resources) =>
  resources
  ->get(~adapter, ~name)
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

let filter = (~name, ~adapter, ~keep, resources) =>
  resources
  ->Js.Dict.entries
  ->Belt.Array.keepMap(((resourceName, resource)) =>
      resourceName->Js.String2.endsWith(createResourceName(~name, ~adapter))
      && keep(name)
        ? Some(resource) : None
    );
