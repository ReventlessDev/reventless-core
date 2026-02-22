type unwrappedResource = ReventlessSpec.Adapter.unwrappedResource

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

let unwrappedToResource = (
  {id, name, urn, info, service}: unwrappedResource,
): ReventlessSpec.Adapter.resource => {
  id: id->Pulumi.Output.make,
  name: name->Pulumi.Output.make,
  urn: urn->Pulumi.Output.make,
  info: info->Pulumi.Output.make,
  service: service->Pulumi.Output.make,
}

let unwrappedToResources = (unwrapped: array<unwrappedResource>) =>
  unwrapped->Array.map(unwrapped => unwrapped->unwrappedToResource)

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
  ->Pulumi.Output.apply(((name, id, urn, info, service)) => {
    let result: unwrappedResource = {name, id, urn, info, service}
    result
  })

let resourcesToUnwrappedOutput = (resources: array<ReventlessSpec.Adapter.resource>) =>
  resources
  ->Array.map(resource => resource->resourceToUnwrappedOutput)
  ->Pulumi.Output.all

let logResource = r => {
  let _ = r->resourceToUnwrappedOutput->Pulumi.Output.apply(r => Console.log2("resource:", r))
}

let unwrappedToString = (resources: array<unwrappedResource>) => {
  resources->Array.filterMap(resource => resource->JSON.stringifyAny)->Array.joinUnsafe(", ")
}

let urns = resources => resources->Array.map((resource: unwrappedResource) => resource.urn)

// ---------------------------------------------------------------------------
// Interop resource conversions
// ReventlessInterop.Resource.t and unwrappedResource are structurally identical
// (name, id, urn, info, service — all plain strings); these helpers bridge the
// two type-system identities without runtime cost.
// ---------------------------------------------------------------------------

let fromInteropUnwrapped = (
  {name, id, urn, info, service}: ReventlessInterop.Resource.t,
): unwrappedResource => {name, id, urn, info, service}

let fromInteropResource = (
  {name, id, urn, info, service}: ReventlessInterop.Resource.t,
): ReventlessSpec.Adapter.resource => {
  id: id->Pulumi.Output.make,
  name: name->Pulumi.Output.make,
  urn: urn->Pulumi.Output.make,
  info: info->Pulumi.Output.make,
  service: service->Pulumi.Output.make,
}

let fromInteropResources = (rs: array<ReventlessInterop.Resource.t>): array<
  ReventlessSpec.Adapter.resource,
> => rs->Array.map(fromInteropResource)
