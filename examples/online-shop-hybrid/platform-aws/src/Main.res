// Platform deployment — admin components, scheduler, shared AppSync API.
// Deploy this stack first; plugin stacks reference its outputs.
//
// The platform also hosts the static host-shell SPA on CloudFront so the
// browser can discover plugin UIs via Platform_UIFragments + Auto UI without
// any per-plugin bundle. The host shell `dist/` lives in the sibling
// reventless-ui workspace and must be built before `pulumi up`.

module Platform = ReventlessAws.Platform.Make()

// Provision (or look up via `platform:cognitoUserPoolId`) the Cognito UserPool
// + SPA client used by Stage D AppSync auth wiring. Exports the pool/client
// IDs and ARN as stack outputs so plugin stacks and the SPA can consume them
// via StackReference. Nothing in the production paths reads these yet.
let _cognitoUserPool = ReventlessAws.Platform_Stack.resolveCognitoUserPool()

let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~hostUiBundle={
    assetsDir: "../../../../reventless-ui/reventless/reventless-host-shell/dist",
    bundleVersion: Reventless.PackageVersion.fromCaller(),
  },
)
