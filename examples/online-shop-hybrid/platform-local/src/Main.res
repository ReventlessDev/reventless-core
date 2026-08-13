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
  //
  // `elevatedGroups` is stated here for the same reason the AWS root states it:
  // it is what lets one shell serve both audiences. An operator goes to the
  // admin API and gets the whole platform; everyone else reads the baked
  // manifest and gets the storefront. Naming the bake without it would send
  // administrators to the storefront too — the shop would work, and the
  // back office would be unreachable.
  ~hostUiBundle={
    bakedManifest: OnlineShopHybridSeed.Storefront.manifest,
    shellConfig: Dict.fromArray([
      ("appName", JSON.Encode.string("Online Shop")),
      (
        "elevatedGroups",
        OnlineShopHybridSeed.Storefront.elevatedGroups
        ->Array.map(JSON.Encode.string)
        ->JSON.Encode.array,
      ),
    ]),
  },
)

Platform.startServers()
