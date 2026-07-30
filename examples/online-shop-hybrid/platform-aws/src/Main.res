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

// Backs the file-upload command input. The framework provisions the presign
// service against this store and serves it read-only from the shell's own
// origin, so an uploaded object is addressable by relative URL and the bucket
// stays private.
let uploadBucket = ReventlessAws.Capability_ObjectStore_S3.make(~name="online-shop-uploads")

// The stores the plugins' fields declare, generated from their committed
// `capabilities.json` manifests — the capability's `plugin` and the plugin's
// registered name are one spelling by construction, which is what retires the
// hand-typed list this file used to carry. After a `@storageRef` change:
// rebuild the plugin, run `pnpm run generate:platform`, review the diff.
// `deployPlugin`'s coverage assertion still catches a platform deployed
// before a regenerate.
let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~hostUiBundle={geocoderPlaceIndex: placeIndex, uploadBucket},
  ~capabilities=PlatformCapabilities.capabilities,
)
