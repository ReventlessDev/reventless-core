// Ordering plugin deployment — bundled variant.

let _ = ReventlessAws.PluginRuntime_Builder.registerDcbConfig(
  ~pluginName="Ordering",
  (),
)

module Platform = ReventlessAws.Platform.Make()
module Ordering = OrderingPlugin_Aws.Make(Platform)

let _ = Platform.deployPlugin(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~plugin=module(Ordering),
)

let default = Pulumi.Pulumi.getOutputs()
