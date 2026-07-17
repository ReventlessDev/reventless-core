/** @pulumi/aws-native/appsync/Api — AppSync Events (Pub/Sub) API.
    Distinct from AppSync GraphQL API (`aws.appsync.GraphQLApi`).
    Used for real-time server-to-client event push via AppSync Events channels.
    See: https://www.pulumi.com/registry/packages/aws-native/api-docs/appsync/api
*/

// ── Auth types ────────────────────────────────────────────────────────────────

/** Authentication mode for connections / publish / subscribe. */
type authMode = {
  /** Auth type string — use the `authType` constants below. */
  authType?: Pulumi.Input.t<string>,
}

/** Optional Cognito User Pool authorization config for an auth provider.
    Required when the provider's `authType` is `AMAZON_COGNITO_USER_POOLS`. */
type cognitoConfig = {
  /** Region the user pool lives in (e.g. "eu-west-1"). */
  awsRegion: Pulumi.Input.t<string>,
  /** Cognito User Pool ID. */
  userPoolId: Pulumi.Input.t<string>,
  /** Optional regex restricting which app client IDs are accepted. */
  appIdClientRegex?: Pulumi.Input.t<string>,
}

/** Auth provider entry for the Events API. */
type authProvider = {
  authType: Pulumi.Input.t<string>,
  /** Required when `authType` is `AMAZON_COGNITO_USER_POOLS`. */
  cognitoConfig?: Pulumi.Input.t<cognitoConfig>,
}

/** IAM authentication type string. */
let awsIam: string = "AWS_IAM"

/** Amazon Cognito User Pools authentication type string. */
let amazonCognitoUserPools: string = "AMAZON_COGNITO_USER_POOLS"

// ── Event config ──────────────────────────────────────────────────────────────

/** Authorization configuration for an AppSync Events API.
    All four array fields are required. */
type eventConfigArgs = {
  /** Auth providers available to the API. */
  authProviders: Pulumi.Input.t<array<Pulumi.Input.t<authProvider>>>,
  /** Auth modes allowed for WebSocket connections. */
  connectionAuthModes: Pulumi.Input.t<array<Pulumi.Input.t<authMode>>>,
  /** Auth modes allowed for publishing events. */
  defaultPublishAuthModes: Pulumi.Input.t<array<Pulumi.Input.t<authMode>>>,
  /** Auth modes allowed for subscribing to channels. */
  defaultSubscribeAuthModes: Pulumi.Input.t<array<Pulumi.Input.t<authMode>>>,
}

// ── Output types ──────────────────────────────────────────────────────────────

/** DNS endpoints for an AppSync Events API.
    Both fields are domain-name-only (no protocol, no path).
    Prepend `https://` for the HTTP endpoint, `wss://` for the realtime endpoint. */
type dns = {
  http?: string,
  realtime?: string,
}

/** Output shape of an `aws-native:appsync/Api` resource. */
type t = {
  /** The API ID (short identifier). */
  apiId: Pulumi.Output.t<string>,
  /** The full ARN of the AppSync Events API. Used for IAM policy resources. */
  apiArn: Pulumi.Output.t<string>,
  /** DNS endpoints. Use `dns.http` for the Lambda `APPSYNC_ENDPOINT` env var. */
  dns: Pulumi.Output.t<dns>,
  /** The name of the AppSync Events API. */
  name: Pulumi.Output.t<string>,
}

// ── Args ──────────────────────────────────────────────────────────────────────

type args = {
  /** Required for Events APIs — omitting creates a plain (GraphQL-style) API. */
  eventConfig?: Pulumi.Input.t<eventConfigArgs>,
  /** Display name for the API resource. Defaults to the Pulumi resource name. */
  name?: Pulumi.Input.t<string>,
}

// ── Constructor ───────────────────────────────────────────────────────────────

@module("@pulumi/aws-native") @scope("appsync") @new
external make: (
  ~name: string,
  ~args: args=?,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
) => t = "Api"
