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

// The stores this platform's plugins declare through `@storageRef`. `plugin`
// must be the name the plugin *registers* (`~name="Catalog"`) — the endpoint map
// is keyed `{plugin}.{store}` from this list while `pluginStructure.requiredStores`
// derives the same key from the registered name, so a case slip produces two keys
// that never meet. `deployPlugin` compares the two sets and fails the deploy when
// a required store is missing from a platform that provisions others.
let capabilities: array<ReventlessInfra.Platform.capability> = [
  ObjectStore({plugin: "Catalog", store: "productImages"}),
]

let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~capabilities,
)
