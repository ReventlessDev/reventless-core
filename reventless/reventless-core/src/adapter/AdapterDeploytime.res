let resolvedToResource: Adapter.resolvedResource => ReventlessInfra.Adapter.resource = ({
  name,
  id,
  urn,
  resourceInfo,
  service,
  role,
  region,
  resourceType,
  configuration,
  tags,
}) => {
  name: name->Pulumi.Output.make,
  id: id->Pulumi.Output.make,
  urn: urn->Pulumi.Output.make,
  resourceInfo: resourceInfo->Pulumi.Output.make,
  service: service->Pulumi.Output.make,
  role: role->Pulumi.Output.make,
  region: region->Pulumi.Output.make,
  resourceType: resourceType->Pulumi.Output.make,
  configuration: configuration->Pulumi.Output.make,
  tags: tags->Pulumi.Output.make,
}

external unsafeUnwrapResource: ReventlessInfra.Adapter.resource => Adapter.resolvedResource =
  "%identity"

let stackRefResourceToResource = stackRefResource =>
  stackRefResource->unsafeUnwrapResource->resolvedToResource // StackReference outputs are not wrapped in Pulumi.Outputs !

// Convert from interop Resource.t directly to a Pulumi-wrapped resource.
// Identical to resolvedToResource but accepts the interop type, avoiding the
// intermediate Adapter.resolvedResource step.
let fromInteropResource: ReventlessInterop.Resource.t => ReventlessInfra.Adapter.resource = ({
  name,
  id,
  urn,
  resourceInfo,
  service,
  role,
  region,
  resourceType,
  configuration,
  tags,
}) => {
  name: name->Pulumi.Output.make,
  id: id->Pulumi.Output.make,
  urn: urn->Pulumi.Output.make,
  resourceInfo: (resourceInfo :> ReventlessInfra.Adapter.resourceInfo)->Pulumi.Output.make,
  service: service->Pulumi.Output.make,
  role: role->Pulumi.Output.make,
  region: region->Pulumi.Output.make,
  resourceType: resourceType->Pulumi.Output.make,
  configuration: configuration->Pulumi.Output.make,
  tags: tags->Pulumi.Output.make,
}
