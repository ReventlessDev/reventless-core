// One platform per app directory. Before Platform.Make(), which opens the store;
// REVENTLESS_DOMAIN_PORT bypasses.
ReventlessLocal.LocalPlatformStart.orAddressRunning()

module Platform = ReventlessLocal.Platform.Make()

// A directory to serve the host UI from instead of the installed shell's own, for an app that
// stages its shell beside the platform.
@val @scope(("process", "env"))
external hostUiDir: Nullable.t<string> = "REVENTLESS_HOST_UI_DIR"

// Before the plugins are built, because component construction is where the
// owner-scoped resolvers read it. Set afterwards it would be set for nothing.
Reventless.OwnerScope.setElevatedRoles(OnlineShopHybridSeed.Storefront.elevatedRoles)

// Backs the notification competency's email channel, the way the AWS root backs
// it with SES — same helper shape, same `~messagingSender` field, same injected
// record reaching `SendNotification`'s `translate`. This one accepts every
// message, prints it to the log and delivers nothing, so the shop's deliveries
// read `Delivered` locally instead of the three-retries-then-failed a platform
// with no mailer produces.
let messagingSender = ReventlessLocal.Capability_Messaging_Log.make()

// Makes, groups and unmakes accounts in `.reventless/users.yaml`, the file the
// local login already reads, so a principal a slice creates can sign in after
// the next restart too. The AWS root has no counterpart yet.
let identityProvider = ReventlessLocal.Capability_IdentityProvider_UserStore.make()

module Catalog = CatalogPlugin.Plugin.Make(Platform)
module Ordering = OrderingPlugin.Plugin.Make(Platform)
// Self-registration, hosted here and not by the AWS root: its doors admit
// callers who are not signed in, and a deployed platform has no door for them
// yet. With the log transport a registration completes with no mailbox at all —
// the code it sends is printed in this process's log.
module Registration = RegistrationPlugin.Plugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(Catalog), module(Ordering), module(Registration)],
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
    assetsDir: ?(hostUiDir->Nullable.toOption),
    // Without this the dev shell applies whatever hints the host-shell package
    // happens to ship, which is that repo's own demonstration file — so the
    // storefront's nav would read right locally for a reason nothing here
    // states, and read wrong the moment it is deployed.
    uiHintsFile: OnlineShopHybridSeed.Storefront.uiHintsFile,
    // Served beside the hints and watched the same way, so editing a renderer is
    // a save and a refresh. `pnpm run dev:full` needs no extra process for it —
    // and deliberately not `dev:ui`, which is for working on the shell's own
    // source and would quietly move this example off the seam it demonstrates.
    uiSlotsFile: OnlineShopHybridSeed.Storefront.uiSlotsFile,
    messagingSender,
    identityProvider,
    shellConfig: Dict.fromArray([
      ("appName", JSON.Encode.string("Online Shop")),
      // The shop opens on the shop. Per-deployment rather than a nav hint: an
      // app has one home, and no view is entitled to claim it.
      ("home", JSON.Encode.string("/Catalog/Products")),
      (
        "elevatedGroups",
        // The groups the server resolved the roles to, so the two cannot differ.
        Reventless.OwnerScope.elevatedGroups()
        ->Array.map(JSON.Encode.string)
        ->JSON.Encode.array,
      ),
    ]),
  },
)

Platform.startServers()
