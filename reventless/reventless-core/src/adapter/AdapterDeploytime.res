let resolvedToResource: Adapter.resolvedResource => Reventless.Adapter.resource = ({
  name,
  id,
  urn,
  info,
  service,
}) => {
  name: name->Pulumi.Output.make,
  id: id->Pulumi.Output.make,
  urn: urn->Pulumi.Output.make,
  info: info->Pulumi.Output.make,
  service: service->Pulumi.Output.make,
}

external unsafeUnwrapResource: Reventless.Adapter.resource => Adapter.resolvedResource =
  "%identity"

let stackRefResourceToResource = stackRefResource =>
  stackRefResource->unsafeUnwrapResource->resolvedToResource // StackReference outputs are not wrapped in Pulumi.Outputs !

// Convert from interop Resource.t directly to a Pulumi-wrapped resource.
// Identical to resolvedToResource but accepts the interop type, avoiding the
// intermediate Adapter.resolvedResource step.
let fromInteropResource: ReventlessInterop.Resource.t => Reventless.Adapter.resource = ({
  name,
  id,
  urn,
  info,
  service,
}) => {
  name: name->Pulumi.Output.make,
  id: id->Pulumi.Output.make,
  urn: urn->Pulumi.Output.make,
  info: info->Pulumi.Output.make,
  service: service->Pulumi.Output.make,
}
