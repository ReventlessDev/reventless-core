open ReventlessSpec.Adapter;

let set: (~adapter: string, ~name: string, resource) => unit;

let get: (~adapter: string, ~name: string) => option(resource);
let getExn: (~adapter: string, ~name: string) => resource;
