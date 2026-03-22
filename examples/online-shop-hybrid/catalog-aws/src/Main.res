// Catalog plugin deployment — bundled variant.
// Uses bundled Lambda handlers for Aggregate and ReadModel components.
// DCB slices use standard CallbackFunction handlers.

let _ = ReventlessAws.PluginRuntime_Builder.registerDcbConfig(
  ~pluginName="Catalog",
  (),
)

module Platform = ReventlessAws.Platform.Make()
module Catalog = CatalogPlugin_Aws.Make(Platform)

Platform.deployPlugin(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~plugin=module(Catalog),
)

let default = Pulumi.Pulumi.getOutputs()
