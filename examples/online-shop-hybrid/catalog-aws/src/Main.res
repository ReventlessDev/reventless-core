// Catalog plugin — AWS deployment.

let _ = ReventlessAws.PluginRuntime_Builder.registerDcbConfig(
  ~pluginName="Catalog",
  (),
)

module Platform = ReventlessAws.Platform.Make()
module Catalog = CatalogPlugin_Aws.Make(Platform)

let _ = Platform.deployPlugin(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~plugin=module(Catalog),
)

let default = Pulumi.Pulumi.getOutputs()
