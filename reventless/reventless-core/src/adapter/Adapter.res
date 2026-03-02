type resolvedResource = ReventlessInfra.Adapter.resolvedResource

let outputToResource: Pulumi.Output.t<
  ReventlessInfra.Adapter.resource,
> => ReventlessInfra.Adapter.resource = resourceOutput => {
  id: resourceOutput->Pulumi.Output.flatMap(r => r.id),
  name: resourceOutput->Pulumi.Output.flatMap(r => r.name),
  urn: resourceOutput->Pulumi.Output.flatMap(r => r.urn),
  info: resourceOutput->Pulumi.Output.flatMap(r => r.info),
  service: resourceOutput->Pulumi.Output.flatMap(r => r.service),
}

let resourcesOutputToResource: Pulumi.Output.t<array<ReventlessInfra.Adapter.resource>> => option<
  ReventlessInfra.Adapter.resource,
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

let resolvedToResource = (
  {id, name, urn, info, service}: resolvedResource,
): ReventlessInfra.Adapter.resource => {
  id: id->Pulumi.Output.make,
  name: name->Pulumi.Output.make,
  urn: urn->Pulumi.Output.make,
  info: info->Pulumi.Output.make,
  service: service->Pulumi.Output.make,
}

let resolvedToResources = (resolved: array<resolvedResource>) =>
  resolved->Array.map(resolved => resolved->resolvedToResource)

let resolvedOutputToResource: Pulumi.Output.t<
  resolvedResource,
> => ReventlessInfra.Adapter.resource = resolvedResource => {
  service: resolvedResource->Pulumi.Output.apply(r => r.service),
  name: resolvedResource->Pulumi.Output.apply(r => r.name),
  id: resolvedResource->Pulumi.Output.apply(r => r.id),
  urn: resolvedResource->Pulumi.Output.apply(r => r.urn),
  info: resolvedResource->Pulumi.Output.apply(r => r.info),
}

let resourceToResolvedOutput = (r: ReventlessInfra.Adapter.resource) =>
  (r.name, r.id, r.urn, r.info, r.service)
  ->Pulumi.Output.all5
  ->Pulumi.Output.apply(((name, id, urn, info, service)) => {
    let result: resolvedResource = {name, id, urn, info, service}
    result
  })

let resourcesToResolvedOutput = (resources: array<ReventlessInfra.Adapter.resource>) =>
  resources
  ->Array.map(resource => resource->resourceToResolvedOutput)
  ->Pulumi.Output.all

let logResource = r => {
  let _ = r->resourceToResolvedOutput->Pulumi.Output.apply(r => Console.log2("resource:", r))
}

let resolvedToString = (resources: array<resolvedResource>) => {
  resources->Array.filterMap(resource => resource->JSON.stringifyAny)->Array.joinUnsafe(", ")
}

let urns = resources => resources->Array.map((resource: resolvedResource) => resource.urn)

// ---------------------------------------------------------------------------
// Interop resource conversions
// ReventlessInterop.Resource.t and resolvedResource are structurally identical
// (name, id, urn, info, service — all plain strings); these helpers bridge the
// two type-system identities without runtime cost.
// ---------------------------------------------------------------------------

let fromInteropResolved = (
  {name, id, urn, info, service}: ReventlessInterop.Resource.t,
): resolvedResource => {name, id, urn, info, service}

let fromInteropResource = (
  {name, id, urn, info, service}: ReventlessInterop.Resource.t,
): ReventlessInfra.Adapter.resource => {
  id: id->Pulumi.Output.make,
  name: name->Pulumi.Output.make,
  urn: urn->Pulumi.Output.make,
  info: info->Pulumi.Output.make,
  service: service->Pulumi.Output.make,
}

let fromInteropResources = (rs: array<ReventlessInterop.Resource.t>): array<
  ReventlessInfra.Adapter.resource,
> => rs->Array.map(fromInteropResource)
