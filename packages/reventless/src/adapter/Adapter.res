type unwrappedResource = {
  name: string,
  id: string,
  urn: string,
  info: string,
  service: string,
}

let outputToResource: Pulumi.Output.t<
  ReventlessSpec.Adapter.resource,
> => ReventlessSpec.Adapter.resource = resourceOutput => {
  id: resourceOutput->Pulumi.Output.flatMap(r => r.id),
  name: resourceOutput->Pulumi.Output.flatMap(r => r.name),
  urn: resourceOutput->Pulumi.Output.flatMap(r => r.urn),
  info: resourceOutput->Pulumi.Output.flatMap(r => r.info),
  service: resourceOutput->Pulumi.Output.flatMap(r => r.service),
}

let resourcesOutputToResource: Pulumi.Output.t<array<ReventlessSpec.Adapter.resource>> => option<
  ReventlessSpec.Adapter.resource,
> = resourcesOutput =>
  try {
    id: resourcesOutput->Pulumi.Output.flatMap(r => (r->Array.getUnsafe(0)).id),
    name: resourcesOutput->Pulumi.Output.flatMap(r => (r->Array.getUnsafe(0)).name),
    urn: resourcesOutput->Pulumi.Output.flatMap(r => (r->Array.getUnsafe(0)).urn),
    info: resourcesOutput->Pulumi.Output.flatMap(r => (r->Array.getUnsafe(0)).info),
    service: resourcesOutput->Pulumi.Output.flatMap(r => (r->Array.getUnsafe(0)).service),
  }->Some catch {
  | _ => None
  }

let unwrappedOutputToResource: Pulumi.Output.t<
  unwrappedResource,
> => ReventlessSpec.Adapter.resource = unwrappedResource => {
  service: unwrappedResource->Pulumi.Output.apply(r => r.service),
  name: unwrappedResource->Pulumi.Output.apply(r => r.name),
  id: unwrappedResource->Pulumi.Output.apply(r => r.id),
  urn: unwrappedResource->Pulumi.Output.apply(r => r.urn),
  info: unwrappedResource->Pulumi.Output.apply(r => r.info),
}

let resourceToUnwrappedOutput = (r: ReventlessSpec.Adapter.resource) =>
  (r.name, r.id, r.urn, r.info, r.service)
  ->Pulumi.Output.all5
  ->Pulumi.Output.apply(((name, id, urn, info, service)) => {name, id, urn, info, service})

let logResource = r => {
  let _ = r->resourceToUnwrappedOutput->Pulumi.Output.apply(r => Js.log2("resource:", r))
}

let unwrappedToString = (resources: array<unwrappedResource>) => {
  resources
  ->Belt.Array.keepMap(resource => resource->Js.Json.stringifyAny)
  ->Js.Array2.joinWith(", ")
}
