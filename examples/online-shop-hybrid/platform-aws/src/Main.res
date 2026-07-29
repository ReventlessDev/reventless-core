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

// The stores the plugins' fields declare. `Catalog.productImages` is the
// requirement `@storageRef("productImages")` states on ChangeProductImage —
// listing it here is what turns that annotation into a provisioned bucket, a
// presign service scoped to its own prefix, and a served path on the shell's
// origin.
//
// `plugin` must be the name the plugin *registers* (`~name="Catalog"`), not a
// lowercase reading of it. The endpoint map is keyed `{plugin}.{store}` from
// this list, while `pluginStructure.requiredStores` derives the same key from
// the registered name — so a case slip here produces two keys that never meet.
// Nothing catches it: the store is provisioned, the endpoint is exported under
// a key no UI queries, and the upload input falls back to the legacy service
// and writes to the wrong bucket with a 2xx and a plausible ref.
//
// Written by hand on purpose. Deriving it from the plugins' structures is the
// next stage; a reviewed hand-written list is what gives the generator a shape
// to emit and a diff to be checked against. This mismatch is the standing cost
// of hand-writing it, and the deploy-time assertion in the analysis's §6 is
// what would make it loud before then.
let capabilities: array<ReventlessInfra.Platform.capability> = [
  ObjectStore({plugin: "Catalog", store: "productImages"}),
]

let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~hostUiBundle={geocoderPlaceIndex: placeIndex, uploadBucket},
  ~capabilities,
)
