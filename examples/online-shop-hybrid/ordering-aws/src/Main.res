// Ordering plugin deployment — bundled variant.
// Uses bundled Lambda handlers for Aggregate and ReadModel components.
// DCB slices use standard CallbackFunction handlers.

module Platform = ReventlessAws.Platform.Make()
module Ordering = OrderingPlugin_Bundled.Make(Platform)

Platform.deployPlugin(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~plugin=module(Ordering),
)

let default = Pulumi.Pulumi.getOutputs()
