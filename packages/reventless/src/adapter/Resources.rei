open ReventlessSpec.Adapter;

let set:
  (~adapter: string, ~name: string, ~resource: resource, resources) => unit;

let get: (~adapter: string, ~name: string, resources) => option(resource);
let getExn: (~adapter: string, ~name: string, resources) => resource;
