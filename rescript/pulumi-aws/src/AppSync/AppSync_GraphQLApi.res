/** @pulumi/aws/appsync/GraphQLApi
  see: https://www.pulumi.com/registry/packages/aws/api-docs/appsync/graphqlapi
*/
type uris = {@as("GRAPHQL") graphQL: string, @as("REALTIME") realtime: string}

type t = {
  id: Pulumi.Output.t<string>,
  arn: Pulumi.Output.t<string>,
  name: Pulumi.Output.t<string>,
  uris: Pulumi.Output.t<uris>,
}
type graphQLApi = t

type defaultAction = ALLOW | DENY
type userPoolConfig = {
  userPoolId: string,
  defaultAction: defaultAction,
  awsRegion?: string,
  appIdClientRegex?: string,
}

type authenticationType =
  | API_KEY
  | AWS_IAM
  | AMAZON_COGNITO_USER_POOLS
  | OPENID_CONNECT

/** `MERGED` turns the API into an AppSync Merged API: it carries no schema of
    its own — source APIs contribute theirs via `AppSync.SourceApiAssociation`
    and AWS composes the merged endpoint. Requires `mergedApiExecutionRoleArn`
    (`appsync:SourceGraphQL` on the associated source APIs; also
    `appsync:StartSchemaMerge` when associations use `MANUAL_MERGE`). */
type apiType =
  | GRAPHQL
  | MERGED

/** Entry of the `additionalAuthenticationProviders` array — minimal shape
    covering the IAM and Cognito cases used by the Reventless platform.
    Extend with `openidConnectConfig` / `lambdaAuthorizerConfig` if needed. */
type additionalAuthenticationProvider = {
  authenticationType: Pulumi.Input.t<authenticationType>,
  userPoolConfig?: Pulumi.Input.t<userPoolConfig>,
}

/** Field-level CloudWatch log verbosity for resolver execution. `ERROR` logs
    only field/resolver errors (e.g. a non-null coercion on a stale read-model
    row) — the server-side capture point that AppSync otherwise swallows into the
    client's `errors[]`; `ALL` also logs request-level tracing (high volume). */
type fieldLogLevel =
  | NONE
  | ERROR
  | ALL

/** CloudWatch logging config. `cloudwatchLogsRoleArn` must be an IAM role
    assumable by `appsync.amazonaws.com` carrying `AWSAppSyncPushToCloudWatchLogs`.
    Resolvers run on the SOURCE APIs under the merged-API topology, so set this on
    the source APIs to capture field-resolver errors. */
type logConfig = {
  cloudwatchLogsRoleArn: Pulumi.Input.t<string>,
  fieldLogLevel: Pulumi.Input.t<fieldLogLevel>,
  excludeVerboseContent?: Pulumi.Input.t<bool>,
}

type args = {
  authenticationType: Pulumi.Input.t<authenticationType>,
  name?: Pulumi.Input.t<string>,
  schema?: Pulumi.Input.t<string>,
  userPoolConfig?: Pulumi.Input.t<userPoolConfig>,
  additionalAuthenticationProviders?: Pulumi.Input.t<
    array<Pulumi.Input.t<additionalAuthenticationProvider>>,
  >,
  apiType?: Pulumi.Input.t<apiType>,
  mergedApiExecutionRoleArn?: Pulumi.Input.t<string>,
  logConfig?: Pulumi.Input.t<logConfig>,
}

@module("@pulumi/aws") @scope("appsync") @new
external make: (
  ~name: string,
  ~args: args=?,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
) => graphQLApi = "GraphQLApi"

@deprecated("use bare make instead")
let makeUnnecessarilyConvenient = (~name, ~userPoolId, ~schema, ~opts=?) =>
  make(
    ~name,
    ~args={
      authenticationType: AMAZON_COGNITO_USER_POOLS->Pulumi.Input.make,
      userPoolConfig: userPoolId
      ->Pulumi.Output.apply(userPoolId => {userPoolId, defaultAction: ALLOW})
      ->Pulumi.Output.asInput,
      schema,
    },
    ~opts?,
  )
