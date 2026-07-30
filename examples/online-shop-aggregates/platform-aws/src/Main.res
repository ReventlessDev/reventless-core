// Platform deployment — admin components, scheduler, shared AppSync API.
// Deploy this stack first; plugin stacks reference its outputs.
//
// Unlike the other two examples, this platform deploys *no* host-shell SPA: it
// omits `~hostUiBundle` entirely. That is the topology where the UI ships from
// its own stack, and it is the reason this example exists in this shape — with
// no shell, the shell's distribution cannot be the thing that serves declared
// object stores, so the platform fronts them itself and exports a `baseUrl` per
// store. The choice is either/or by construction: S3 allows one bucket policy
// per bucket, so two distributions serving one store would overwrite each
// other's read grant. `Util_StoreLayout.servingFor` is where it is decided.

module Platform = ReventlessAws.Platform.Make()

// The stores this platform's plugins declare through `@storageRef`, generated
// from their committed `capabilities.json` manifests so the capability's
// `plugin` and the plugin's registered name are one spelling by construction.
// After a `@storageRef` change: rebuild the plugin, run
// `pnpm run generate:platform`, review the diff. `deployPlugin` compares the
// deployed sets and fails the deploy when a required store is missing from a
// platform that provisions others.
let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~capabilities=PlatformCapabilities.capabilities,
)
