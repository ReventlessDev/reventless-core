// Platform deployment — admin components, scheduler, shared AppSync API.
// Deploy this stack first; plugin stacks reference its outputs.
//
// The platform also hosts the static host-shell SPA on CloudFront so the
// browser can discover plugin UIs via Platform_UIFragments + Auto UI without
// any per-plugin bundle.

// Attach CloudWatch alarms to every execution unit this stack provisions —
// command handlers, projections, reactors, collectors, tasks, the scheduler, the
// dead-letter sink. Registered before anything is built, because the seam hands a
// backend each unit as it is provisioned.
//
// It provisions nothing until the deployment names somewhere for alerts to go
// (`alarmEmail` or `alarmTopicArn`), which this repository deliberately does not
// commit: where an alert goes is per-deployment and usually somebody's inbox. Set
// `REVENTLESS_ALARM_EMAIL` in CI, or `alarmEmail:` in a gitignored
// `Pulumi.local.yaml`, and the next deploy grows a topic and one alarm per unit.
//
// Unconfigured, this line is free — and it is committed anyway so that turning an
// estate's monitoring on is a config key rather than a code change nobody
// remembers to make. An unwatched stack found its last two framework defects by
// way of a CloudWatch bill.
ReventlessAws.Monitoring_CloudWatch.use()

module Platform = ReventlessAws.Platform.Make()

// Backs the geo-point command input's address search. Provisioning it here
// declares that this deployment wants geocoding; the framework wires the client
// door — a Cognito-authenticated `Query.geocode` resolver on the platform API —
// and exports the index name for the unattended slice path (D9 half 2).
//
// The browser half lives in the commercial map view, which a deployment stages
// beside the shell under its licence. This example stages none (see `viewModes`
// below), so here the index serves the unattended path only.
let placeIndex = ReventlessAws.Capability_Geocoding_AwsLocation.make(~name="online-shop-geocoder")

// Backs the notification competency's email channel. Unlike the geocoder there
// is no client door: a browser has no business sending mail from this
// deployment's identity, so the only caller is the send slice's Lambda, which
// reaches SES through the injected capability record.
//
// **Neither the transport nor the address is here, and that is the point.**
// Whether a stack mails anybody is a per-environment decision — alpha and beta
// use the log transport, which prints each message and sends nothing — and a
// verified identity per AWS account, so this file cannot name one true for every
// stack built from it. Naming a placeholder address would be worse than naming
// nothing: it provisions an identity nobody can verify, after which every send is
// refused at the sender while reading like a delivery problem. The stack states
// both:
//
//   platform:messagingEmailProvider    ses | log                 (default: ses)
//   platform:messagingEmailSender      orders@your-shop.example  (required for ses)
//   platform:messagingEmailSenderName  Your Shop                 (optional From:)
//
// `SendNotification` declares the Messaging capability, so a stack choosing `ses`
// and naming no address is refused at deploy time naming the key, rather than
// deploying green and dropping every confirmation.
//
// **Provisioning SES is not the same as being able to send.** Creating the
// identity asks AWS to mail the address; until somebody follows that link SES
// refuses everything, and the deploy will have succeeded regardless. The first
// confirmations queue and are swept rather than being written off, which is the
// behavior that makes a pending verification survivable. Reaching unverified
// recipients additionally means leaving the SES sandbox, which is an
// account-level request rather than anything this deploy can do.
let messagingSender = ReventlessAws.Capability_Messaging.make(~name="online-shop-sender")

// The stores the plugins' fields declare, generated from their committed
// `capabilities.json` manifests — the capability's `plugin` and the plugin's
// registered name are one spelling by construction, which is what retires the
// hand-typed list this file used to carry. After a `@storageRef` change:
// rebuild the plugin, run `pnpm run generate:platform`, review the diff.
// `deployPlugin`'s coverage assertion still catches a platform deployed
// before a regenerate.
let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  // No `viewModes`. The map and graph views are commercial packages the shell
  // loads as federation remotes a deployment stages beside it under its licence
  // (`uiModules` in config.json). This example stages none: the packages are
  // private, and a free example must install anonymously. Naming the modes
  // without their remotes only makes the shell warn at boot that nothing
  // provides them. The local platform stages every installed view instead.
  //
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
    geocoderPlaceIndex: placeIndex,
    messagingSender,
    // The storefront's surface, shared with the in-memory root that hosts the
    // same shop. Declaring it is what points the shell at a static manifest for
    // its non-elevated audience; `elevatedGroups` below is what keeps an
    // operator on the admin API instead. Neither is a security boundary — the
    // server decides what a caller may do, and decides it the same either way.
    bakedManifest: OnlineShopHybridSeed.Storefront.manifest,
    // The same hints file the in-memory root serves. The deploy excludes the
    // host-shell package's own `ui-hints.json` as the dev-mode fallback it is,
    // so a deployed shop with nothing declared here has no curated nav at all.
    uiHintsFile: OnlineShopHybridSeed.Storefront.uiHintsFile,
    // The same module the in-memory root serves. Written beside `config.json`
    // and named by the `uiSlotsUrl` the deploy computes — both, because the file
    // alone is one nothing imports.
    uiSlotsFile: OnlineShopHybridSeed.Storefront.uiSlotsFile,
    shellConfig: Dict.fromArray([
      ("appName", JSON.Encode.string("Online Shop")),
      ("home", JSON.Encode.string("/Catalog/Products")),
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
