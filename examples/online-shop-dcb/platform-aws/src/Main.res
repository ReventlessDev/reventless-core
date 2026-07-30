// Platform deployment — admin components, scheduler, shared AppSync API.
// Deploy this stack first; plugin stacks reference its outputs.
//
// The platform also hosts the static host-shell SPA on CloudFront so the
// browser can discover plugin UIs via Platform_UIFragments + Auto UI without
// any per-plugin bundle. Passing `~hostUiBundle` is what opts into that
// hosting; this deployment takes every default it offers.

module Platform = ReventlessAws.Platform.Make()

let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~hostUiBundle={},
  // Empty today — no plugin declares a store. Generated all the same, so a
  // future `@storageRef` flows through `pnpm run generate:platform` as a
  // reviewable diff instead of a hand edit here.
  ~capabilities=PlatformCapabilities.capabilities,
)
