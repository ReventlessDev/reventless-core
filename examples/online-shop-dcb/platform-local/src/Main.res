// One platform per app directory. Before Platform.Make(), which opens the store;
// REVENTLESS_DOMAIN_PORT bypasses.
ReventlessLocal.LocalPlatformStart.orAddressRunning()

module Platform = ReventlessLocal.Platform.Make()

module Catalog = CatalogPlugin.Plugin.Make(Platform)
module Ordering = OrderingPlugin.Plugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(Catalog), module(Ordering)],
)

Platform.startServers()
