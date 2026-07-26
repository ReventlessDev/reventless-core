// Platform deployment — admin components, scheduler, shared AppSync API.
// Deploy this stack first; plugin stacks reference its outputs.
//
// The platform also hosts the static host-shell SPA on CloudFront so the
// browser can discover plugin UIs via Platform_UIFragments + Auto UI without
// any per-plugin bundle. The host shell `dist/` ships inside the published
// `@reventlessdev/reventless-host-shell` package (`prepublishOnly` runs `vite
// build` so the registry tarball carries pre-built bundle output). We resolve
// the package via Node's module resolver so the location works regardless of
// pnpm's installed layout (hoisted root vs nested per-workspace).

module Platform = ReventlessAws.Platform.Make()

// Provision (or look up via `platform:cognitoUserPoolId`) the Cognito UserPool
// + SPA client used by Stage D AppSync auth wiring. Exports the pool/client
// IDs and ARN as stack outputs so plugin stacks and the SPA can consume them
// via StackReference. Nothing in the production paths reads these yet.
let _cognitoUserPool = ReventlessAws.Platform_Stack.resolveCognitoUserPool()

let hostShellDist =
  ReventlessAws.Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-host-shell") ++ "/dist"

// AWS Location place index backing the geo-point command input's address
// search. Its name is threaded into hostUiBundle as `geocoderPlaceIndex`, which
// provisions the public geocoder Function URL and writes `geocoderEndpoint` into
// config.json. Esri/SingleUse is the cheapest tier for interactive geocoding.
let placeIndex = PulumiAws.Location.PlaceIndex.make(
  ~name="online-shop-geocoder",
  ~args={
    indexName: Pulumi.Input.make("online-shop-geocoder"),
    dataSource: Pulumi.Input.make("Esri"),
    dataSourceConfiguration: Pulumi.Input.make({
      PulumiAws.Location.PlaceIndex.intendedUse: Pulumi.Input.make("SingleUse"),
    }),
  },
)

// Bucket the file-upload command input PUTs into via a presigned URL. Browser
// PUT/POST CORS is required for the direct-to-bucket upload. Its name is threaded
// into hostUiBundle as `uploadBucketName` (with `enableUploads`), provisioning
// the presign Function URL and writing `uploadEndpoint` into config.json.
let uploadBucket = PulumiAws.S3.Bucket.make(
  ~name="online-shop-uploads",
  ~args={
    corsRules: [
      {
        PulumiAws.S3.Bucket.allowedHeaders: ["*"],
        allowedMethods: ["HEAD", "GET", "PUT", "POST"],
        allowedOrigins: ["*"],
        exposeHeaders: ["ETag"],
        maxAgeSeconds: 3000,
      },
    ]->Pulumi.Input.make,
  },
)

let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~hostUiBundle={
    assetsDir: hostShellDist,
    bundleVersion: Reventless.PackageVersion.fromCaller(),
    // Threading the resolved outputs (not literals) so Pulumi orders the
    // geocoder/upload Function URLs after the index/bucket they depend on.
    geocoderPlaceIndex: placeIndex.indexName->Pulumi.Output.asInput,
    enableUploads: true,
    uploadBucketName: uploadBucket.bucket->Pulumi.Output.asInput,
    // Serve the private uploads bucket read-only to the UI under `/uploads/*` on
    // the host-shell's own CloudFront origin. The presign service returns a
    // same-origin `/uploads/<key>` ref that renders directly — no public bucket.
    servedBuckets: [
      {
        prefix: "uploads",
        bucketId: uploadBucket.id->Pulumi.Output.asInput,
        bucketArn: uploadBucket.arn->Pulumi.Output.asInput,
        bucketRegionalDomainName: uploadBucket.bucketRegionalDomainName->Pulumi.Output.asInput,
      },
    ],
  },
)
