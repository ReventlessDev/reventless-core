type resolvedResource = ReventlessInfra.Adapter.resolvedResource

let outputToResource: Pulumi.Output.t<
  ReventlessInfra.Adapter.resource,
> => ReventlessInfra.Adapter.resource = resourceOutput => {
  id: resourceOutput->Pulumi.Output.flatMap(r => r.id),
  name: resourceOutput->Pulumi.Output.flatMap(r => r.name),
  urn: resourceOutput->Pulumi.Output.flatMap(r => r.urn),
  resourceInfo: resourceOutput->Pulumi.Output.flatMap(r => r.resourceInfo),
  service: resourceOutput->Pulumi.Output.flatMap(r => r.service),
  role: resourceOutput->Pulumi.Output.flatMap(r => r.role),
  region: resourceOutput->Pulumi.Output.flatMap(r => r.region),
  resourceType: resourceOutput->Pulumi.Output.flatMap(r => r.resourceType),
  configuration: resourceOutput->Pulumi.Output.flatMap(r => r.configuration),
}

let resourcesOutputToResource: Pulumi.Output.t<array<ReventlessInfra.Adapter.resource>> => option<
  ReventlessInfra.Adapter.resource,
> = resourcesOutput =>
  try {
    id: resourcesOutput->Pulumi.Output.flatMap(r => (r->Array.getUnsafe(0)).id),
    name: resourcesOutput->Pulumi.Output.flatMap(r => (r->Array.getUnsafe(0)).name),
    urn: resourcesOutput->Pulumi.Output.flatMap(r => (r->Array.getUnsafe(0)).urn),
    resourceInfo: resourcesOutput->Pulumi.Output.flatMap(r => (r->Array.getUnsafe(0)).resourceInfo),
    service: resourcesOutput->Pulumi.Output.flatMap(r => (r->Array.getUnsafe(0)).service),
    role: resourcesOutput->Pulumi.Output.flatMap(r => (r->Array.getUnsafe(0)).role),
    region: resourcesOutput->Pulumi.Output.flatMap(r => (r->Array.getUnsafe(0)).region),
    resourceType: resourcesOutput->Pulumi.Output.flatMap(r => (r->Array.getUnsafe(0)).resourceType),
    configuration: resourcesOutput->Pulumi.Output.flatMap(r =>
      (r->Array.getUnsafe(0)).configuration
    ),
  }->Some catch {
  | _ => None
  }

let resolvedToResource = (
  {id, name, urn, resourceInfo, service, role, region, resourceType, configuration}: resolvedResource,
): ReventlessInfra.Adapter.resource => {
  id: id->Pulumi.Output.make,
  name: name->Pulumi.Output.make,
  urn: urn->Pulumi.Output.make,
  resourceInfo: resourceInfo->Pulumi.Output.make,
  service: service->Pulumi.Output.make,
  role: role->Pulumi.Output.make,
  region: region->Pulumi.Output.make,
  resourceType: resourceType->Pulumi.Output.make,
  configuration: configuration->Pulumi.Output.make,
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
  resourceInfo: resolvedResource->Pulumi.Output.apply(r => r.resourceInfo),
  role: resolvedResource->Pulumi.Output.apply(r => r.role),
  region: resolvedResource->Pulumi.Output.apply(r => r.region),
  resourceType: resolvedResource->Pulumi.Output.apply(r => r.resourceType),
  configuration: resolvedResource->Pulumi.Output.apply(r => r.configuration),
}

let resourceToResolvedOutput = (r: ReventlessInfra.Adapter.resource) =>
  (r.name, r.id, r.urn, r.resourceInfo, r.service, r.role)
  ->Pulumi.Output.all6
  ->Pulumi.Output.flatMap(((name, id, urn, resourceInfo, service, role)) =>
    (r.region, r.resourceType, r.configuration)
    ->Pulumi.Output.all3
    ->Pulumi.Output.apply(((region, resourceType, configuration)) => {
      let result: resolvedResource = {
        name,
        id,
        urn,
        resourceInfo,
        service,
        role,
        region,
        resourceType,
        configuration,
      }
      result
    })
  )

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
// ReventlessInterop.Resource.t and resolvedResource are structurally identical;
// these helpers bridge the two type-system identities without runtime cost.
// ---------------------------------------------------------------------------

let toInteropResource = (
  {name, id, urn, resourceInfo, service, role, region, resourceType, configuration}: resolvedResource,
): ReventlessInterop.Resource.t => {
  name,
  id,
  urn,
  resourceInfo: (resourceInfo :> ReventlessInterop.Resource.resourceInfo),
  service,
  role,
  region,
  resourceType,
  configuration,
}

let resourcesToInterop = (resources: array<ReventlessInfra.Adapter.resource>) =>
  resources
  ->resourcesToResolvedOutput
  ->Pulumi.Output.apply(rs => rs->Array.map(toInteropResource))

let fromInteropResolved = (
  {name, id, urn, resourceInfo, service, role, region, resourceType, configuration}: ReventlessInterop.Resource.t,
): resolvedResource => {
  name,
  id,
  urn,
  resourceInfo: (resourceInfo :> ReventlessInfra.Adapter.resourceInfo),
  service,
  role,
  region,
  resourceType,
  configuration,
}

let fromInteropResource = (
  {name, id, urn, resourceInfo, service, role, region, resourceType, configuration}: ReventlessInterop.Resource.t,
): ReventlessInfra.Adapter.resource => {
  id: id->Pulumi.Output.make,
  name: name->Pulumi.Output.make,
  urn: urn->Pulumi.Output.make,
  resourceInfo: (resourceInfo :> ReventlessInfra.Adapter.resourceInfo)->Pulumi.Output.make,
  service: service->Pulumi.Output.make,
  role: role->Pulumi.Output.make,
  region: region->Pulumi.Output.make,
  resourceType: resourceType->Pulumi.Output.make,
  configuration: configuration->Pulumi.Output.make,
}

let fromInteropResources = (rs: array<ReventlessInterop.Resource.t>): array<
  ReventlessInfra.Adapter.resource,
> => rs->Array.map(fromInteropResource)
