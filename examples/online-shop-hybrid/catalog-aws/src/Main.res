// Catalog plugin deployment — deploys as an independent Pulumi stack.
// Reads platform stack outputs via StackReference (configured in Pulumi.<env>.yaml).

module Platform = ReventlessAws.Platform.Make()
module Catalog = CatalogPlugin.CatalogPlugin.Make(Platform)

Platform.deployPlugin(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugin=module(Catalog),
)
