module Platform = ReventlessLocal.Platform.Make()

module Catalog = CatalogPlugin.Plugin.Make(Platform)
module Ordering = OrderingPlugin.Plugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(Catalog), module(Ordering)],
  // The storefront's surface is app data, shared with every platform that
  // hosts this shop; this root only decides that it hosts one.
  ~hostUiBundle={bakedManifest: OnlineShopHybridSeed.Storefront.manifest},
)

Platform.startServers()
