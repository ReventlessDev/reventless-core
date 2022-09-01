open ReventlessSpec.Adapter;
open Adapter;

let straightToResource: straightResource => resource =
  straightResource =>
    resource(
      ~service=straightResource##service->Pulumi.Output.make,
      ~name=straightResource##name->Pulumi.Output.make,
      ~id=straightResource##id->Pulumi.Output.make,
      ~urn=straightResource##urn->Pulumi.Output.make,
      ~info=straightResource##info->Pulumi.Output.make,
    );

external unsafeResourceToStraight: resource => straightResource = "%identity";

let stackRefResourceToResource = stackRefResource =>
  stackRefResource
  ->unsafeResourceToStraight // StackReference outputs are not wrapped in Pulumi.Outputs !
  ->straightToResource;
