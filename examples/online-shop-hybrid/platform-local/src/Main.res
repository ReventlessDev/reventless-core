module Platform = ReventlessLocal.Platform.Make()

// Before the plugins are built, because component construction is where the
// owner-scoped resolvers read it. Set afterwards it would be set for nothing.
Reventless.OwnerScope.setElevatedGroups(OnlineShopHybridSeed.Storefront.elevatedGroups)

// Backs the notification competency's email channel, the way the AWS root backs
// it with SES — same helper shape, same `~messagingSender` field, same injected
// record reaching `SendNotification`'s `translate`. This one accepts every
// message, prints it to the log and delivers nothing, so the shop's deliveries
// read `Delivered` locally instead of the three-retries-then-failed a platform
// with no mailer produces.
let messagingSender = ReventlessLocal.Capability_Messaging_Log.make()

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
    // Without this the dev shell applies whatever hints the host-shell package
    // happens to ship, which is that repo's own demonstration file — so the
    // storefront's nav would read right locally for a reason nothing here
    // states, and read wrong the moment it is deployed.
    uiHintsFile: OnlineShopHybridSeed.Storefront.uiHintsFile,
    messagingSender,
    shellConfig: Dict.fromArray([
      ("appName", JSON.Encode.string("Online Shop")),
      // The shop opens on the shop. Per-deployment rather than a nav hint: an
      // app has one home, and no view is entitled to claim it.
      ("home", JSON.Encode.string("/Catalog/Products")),
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
