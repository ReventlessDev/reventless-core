// Ordering plugin deployment — bundled variant.

module Platform = ReventlessAws.Platform.Make()
module Ordering = OrderingPlugin_Aws.Make(Platform)

Platform.deployPlugin(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~plugin=module(Ordering),
)

let default = Pulumi.Pulumi.getOutputs()
