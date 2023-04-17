open ReventlessSpec.Adapter
open Adapter

let unwrappedToResource: unwrappedResource => resource = unwrappedResource =>
  resource(
    ~service=unwrappedResource["service"]->Pulumi.Output.make,
    ~name=unwrappedResource["name"]->Pulumi.Output.make,
    ~id=unwrappedResource["id"]->Pulumi.Output.make,
    ~urn=unwrappedResource["urn"]->Pulumi.Output.make,
    ~info=unwrappedResource["info"]->Pulumi.Output.make,
  )

external unsafeUnwrapResource: resource => unwrappedResource = "%identity"

let stackRefResourceToResource = stackRefResource =>
  stackRefResource->unsafeUnwrapResource->unwrappedToResource // StackReference outputs are not wrapped in Pulumi.Outputs !
