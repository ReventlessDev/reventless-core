// Platform deployment — admin components, scheduler, shared AppSync API.
// Deploy this stack first; plugin stacks reference its outputs.
//
// The platform also hosts the static host-shell SPA on CloudFront so the
// browser can discover plugin UIs via Platform_UIFragments + Auto UI without
// any per-plugin bundle.

module Platform = ReventlessAws.Platform.Make()

// Backs the geo-point command input's address search. Provisioning it here
// declares that this deployment wants geocoding; the framework wires the client
// door — a Cognito-authenticated `Query.geocode` resolver on the platform API —
// and exports the index name for the unattended slice path (D9 half 2).
//
// The browser half is only reachable because `~hostUiBundle` below names the `Map`
// view mode: the shell's geocoder issues the `geocode` query from inside the
// dynamically-imported map chunk, and that same mode registers the geo-point
// command input. Drop one and keep the other and this index is a capability no
// browser reaches.
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
  // `Map({})` — the mode with its defaults. No `style`: the mode's built-in
  // demo tiles are the honest default for an example, and a real style URL is a
  // per-deployment key with an account behind it.
  // `shellConfig` carries the keys the shell owns and the deploy has no way to
  // compute. `appName` is what the host UI puts in its sidebar and browser tab;
  // without it the shell falls back to the framework's own name.
  //
  // `elevatedGroups` is the browser's mirror of the rule the server enforces: it
  // decides whether the generated form asks for the owner field or supplies it,
  // and whether the owner column is worth a column. It is read from the shop's
  // own declaration rather than restated, because a mirror that disagrees with
  // the server is the failure this key exists to avoid — and the shell treats an
  // absent key as "unknown", so leaving it out silently stops hiding anything.
  ~hostUiBundle={
    viewModes: [Map({})],
    geocoderPlaceIndex: placeIndex,
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
  ~capabilities=PlatformCapabilities.capabilities,
)
