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

let unwrappedToResource: unwrappedResource => ReventlessSpec.Adapter.resource = unwrappedResource => {
  ReventlessSpec.Adapter.name: unwrappedResource.name->Pulumi.Output.make,
  id: unwrappedResource.id->Pulumi.Output.make,
  urn: unwrappedResource.urn->Pulumi.Output.make,
  info: unwrappedResource.info->Pulumi.Output.make,
  service: unwrappedResource.service->Pulumi.Output.make,
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

let logResource = (r: ReventlessSpec.Adapter.resource) => {
  let _ = r.name->Pulumi.Output.apply(name => Js.log2("Resource: ", name))
  let _ = r.id->Pulumi.Output.apply(id => Js.log2("  id: ", id))
  let _ = r.urn->Pulumi.Output.apply(urn => Js.log2("  urn: ", urn))
  let _ = r.service->Pulumi.Output.apply(service => Js.log2("  service: ", service))
}
