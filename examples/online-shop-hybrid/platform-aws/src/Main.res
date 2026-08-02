// Platform deployment — admin components, scheduler, shared AppSync API.
// Deploy this stack first; plugin stacks reference its outputs.
//
// The platform also hosts the static host-shell SPA on CloudFront so the
// browser can discover plugin UIs via Platform_UIFragments + Auto UI without
// any per-plugin bundle.

module Platform = ReventlessAws.Platform.Make()

// Backs the geo-point command input's address search. Provisioning it here
// declares that this deployment wants geocoding; the framework wires the public
// geocoder Function URL and writes `geocoderEndpoint` into config.json.
let placeIndex = ReventlessAws.Capability_Geocoding_AwsLocation.make(~name="online-shop-geocoder")

// The stores the plugins' fields declare, generated from their committed
// `capabilities.json` manifests — the capability's `plugin` and the plugin's
// registered name are one spelling by construction, which is what retires the
// hand-typed list this file used to carry. After a `@storageRef` change:
// rebuild the plugin, run `pnpm run generate:platform`, review the diff.
// `deployPlugin`'s coverage assertion still catches a platform deployed
// before a regenerate.
let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~hostUiBundle={geocoderPlaceIndex: placeIndex},
  ~capabilities=PlatformCapabilities.capabilities,
)
