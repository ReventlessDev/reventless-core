module Platform = ReventlessLocal.Platform.Make()

// Before the plugins are built, because component construction is where the
// owner-scoped resolvers read it. Set afterwards it would be set for nothing.
Reventless.OwnerScope.setElevatedGroups(OnlineShopHybridSeed.Storefront.elevatedGroups)

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
