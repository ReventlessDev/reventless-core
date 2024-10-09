let unwrappedToResource: Adapter.unwrappedResource => ReventlessSpec.Adapter.resource = ({
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

external unsafeUnwrapResource: ReventlessSpec.Adapter.resource => Adapter.unwrappedResource =
  "%identity"

let stackRefResourceToResource = stackRefResource =>
  stackRefResource->unsafeUnwrapResource->unwrappedToResource // StackReference outputs are not wrapped in Pulumi.Outputs !
