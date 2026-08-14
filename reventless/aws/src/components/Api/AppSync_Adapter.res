// AppSync_Adapter — implements ReventlessInfra.Api_Adapter.Provider for AWS AppSync.
//
// Creates a new AppSync GraphQL API and IAM execution role.
// updateSchema uses the AWS AppSync SDK to push a stitched SDL whenever plugins connect.

open PulumiAws

let log = ReventlessCore.Logger.fromEnv()

// ── SHA-256 helper ─────────────────────────────────────────────────────────

let sha256Hex = (input: string): string =>
  NodeCrypto.createHash("sha256")->NodeCrypto.hashUpdate(input)->NodeCrypto.hashDigest("hex")

// ── Inline AppSync SDK binding ─────────────────────────────────────────────

type appSyncClient

// AWS SDK v3 command pattern: client.send(new StartSchemaCreationCommand({...}))
type startSchemaCreationInput = {
  apiId: string,
  definition: string,
}

type startSchemaCreationCommand

@module("@aws-sdk/client-appsync") @new
external makeAppSyncClient: unit => appSyncClient = "AppSyncClient"

@module("@aws-sdk/client-appsync") @new
external makeStartSchemaCreationCommand: startSchemaCreationInput => startSchemaCreationCommand =
  "StartSchemaCreationCommand"

@send
external send: (appSyncClient, startSchemaCreationCommand) => promise<unknown> = "send"

let startSchemaCreation = (client: appSyncClient, input: startSchemaCreationInput) =>
  client->send(input->makeStartSchemaCreationCommand)

// Retrying wrapper: AppSync holds an API-level lock during schema creation and
// rejects concurrent StartSchemaCreation calls with HTTP 409
// ConcurrentModificationException ("Schema is currently being altered, please
// wait until that is complete."). When multiple processes deploy plugin stacks
// in parallel against the same AppSync API, they race on this lock. Retry with
// jittered exponential backoff so a losing call can wait for the in-progress
// schema to finish and try again. Permanent errors (e.g. invalid SDL) are not
// retried — see AppSync_Error.classify.
let startSchemaCreationRetrying = (
  client: appSyncClient,
  input: startSchemaCreationInput,
): promise<unit> => {
  Effect.tryPromise(
    ~catch=AppSync_Error.classify,
    () => startSchemaCreation(client, input)->Promise.then(_ => Promise.resolve()),
  )
  ->Effect.retry(AppSync_Error.retrySchedule)
  ->Effect.runPromise
}

// GetSchemaCreationStatus — poll until schema is ACTIVE
type getSchemaCreationStatusInput = {apiId: string}
type getSchemaCreationStatusCommand
type getSchemaCreationStatusResult = {status: string, details: option<string>}

@module("@aws-sdk/client-appsync") @new
external makeGetSchemaCreationStatusCommand: getSchemaCreationStatusInput => getSchemaCreationStatusCommand =
  "GetSchemaCreationStatusCommand"

@send
external sendGetStatus: (appSyncClient, getSchemaCreationStatusCommand) => promise<getSchemaCreationStatusResult> =
  "send"

let rec waitForSchemaActive = async (client, apiId, ~maxAttempts=30, ~attempt=0) => {
  let result = await client->sendGetStatus(
    {apiId: apiId}->makeGetSchemaCreationStatusCommand,
  )
  switch result.status {
  | "ACTIVE" | "SUCCESS" => ()
  | "FAILED" =>
    let details = result.details->Option.getOr("(no details)")
    JsError.throwWithMessage(`Schema creation failed for API ${apiId}: ${details}`)
  | status if attempt >= maxAttempts =>
    JsError.throwWithMessage(
      `Schema creation timed out after ${maxAttempts->Int.toString} attempts (status: ${status})`,
    )
  | _ =>
    await Promise.make((resolve, _) => setTimeout(resolve, 500)->ignore)
    await waitForSchemaActive(client, apiId, ~maxAttempts, ~attempt=attempt + 1)
  }
}

// Lazy singleton AppSync client (runtime only)
let _client: ref<option<appSyncClient>> = ref(None)
let getClient = () =>
  switch _client.contents {
  | Some(c) => c
  | None =>
    let c = makeAppSyncClient()
    _client.contents = Some(c)
    c
  }

// ── GetSourceApiAssociation — merged-API association status poll ──────────
// Merged-API deploys must fail loudly on MERGE_FAILED (plan
// merged-api-push-free-composition, Phase 0 finding: a failed merge silently
// keeps the last-good merged schema serving). After creating a
// SourceApiAssociation, poll until the initial merge lands.
type getSourceApiAssociationInput = {
  associationId: string,
  mergedApiIdentifier: string,
}
type getSourceApiAssociationCommand
type sourceApiAssociationSummary = {
  sourceApiAssociationStatus: option<string>,
  sourceApiAssociationStatusDetail: option<string>,
}
type getSourceApiAssociationResult = {sourceApiAssociation: option<sourceApiAssociationSummary>}

@module("@aws-sdk/client-appsync") @new
external makeGetSourceApiAssociationCommand: getSourceApiAssociationInput => getSourceApiAssociationCommand =
  "GetSourceApiAssociationCommand"

@send
external sendGetSourceApiAssociation: (
  appSyncClient,
  getSourceApiAssociationCommand,
) => promise<getSourceApiAssociationResult> = "send"

// Poll until the association reports MERGE_SUCCESS; throw with the AWS status
// detail on MERGE_FAILED / AUTO_MERGE_SCHEDULE_FAILED. Auto-merge lands in
// ~12 s (spike-measured), so 60 × 2 s bounds the wait at two minutes.
let rec waitForMergeSuccess = async (
  client: appSyncClient,
  ~associationId: string,
  ~mergedApiIdentifier: string,
  ~maxAttempts=60,
  ~attempt=0,
  ~delayMs=2000,
) => {
  let result = await client->sendGetSourceApiAssociation(
    {associationId, mergedApiIdentifier}->makeGetSourceApiAssociationCommand,
  )
  let status =
    result.sourceApiAssociation
    ->Option.flatMap(a => a.sourceApiAssociationStatus)
    ->Option.getOr("(no status)")
  let detail =
    result.sourceApiAssociation
    ->Option.flatMap(a => a.sourceApiAssociationStatusDetail)
    ->Option.getOr("(no details)")
  switch status {
  | "MERGE_SUCCESS" => ()
  | "MERGE_FAILED" | "AUTO_MERGE_SCHEDULE_FAILED" =>
    JsError.throwWithMessage(
      `Source API association ${associationId} on ${mergedApiIdentifier} failed to merge (${status}): ${detail}`,
    )
  | _ if attempt >= maxAttempts =>
    JsError.throwWithMessage(
      `Source API association ${associationId} merge timed out after ${maxAttempts->Int.toString} attempts (status: ${status})`,
    )
  | _ =>
    await Promise.make((resolve, _) => setTimeout(resolve, delayMs)->ignore)
    await waitForMergeSuccess(
      client,
      ~associationId,
      ~mergedApiIdentifier,
      ~maxAttempts,
      ~attempt=attempt + 1,
      ~delayMs,
    )
  }
}

// ── Cognito group directive injection ─────────────────────────────────────
// Injects @aws_cognito_user_pools(cognito_groups: [...]) directives into SDL
// field strings based on authorization metadata from schema entries.
//
// Two sources are merged:
//   1. The legacy `authorization?: {tableName, group}` field — single group
//      per entry, kept for the indexed-access auth path.
//   2. The Stage E2 spec-level `Authorization.permission` fields
//      (`fieldPermissions` on mutations, `permission` on queries) — derived
//      from `@@reventless.authorize` / `@authorize` PPX annotations.
//
// When both are present on the same field, the spec-level permission wins
// (it is more specific). `AllowGroups([g1, g2, ...])` emits
// `@aws_cognito_user_pools(cognito_groups: ["g1", "g2", ...])`.
// `AllowAuthenticated` / `AllowAnonymous` emit no directive (with Cognito as
// primary auth, any reaching request is already authenticated). `AllowGroups([])`
// and `DenyAll` emit a sentinel `__deny_all__` group that no Cognito user can
// belong to — effectively blocking the field at the API layer.
//
// NOT `@aws_auth(...)`: that is the single-mode form, which AppSync ignores on a
// multi-auth API — which every API this adapter provisions is. See
// `AppSync_SdlDecorate.formatCognitoGroupsDirective` for the full rationale and
// the observation that established it.
//
// ── Dual-auth (Cognito + IAM) for deploy-time system callers ────────────────
// A field flagged `systemCallable` (via `mutationSchemaEntry`/`querySchemaEntry`)
// must be reachable by BOTH the console UI (Cognito) and a deploy-time system
// caller signing SigV4 with ambient AWS credentials (`Util_AppSync_Caller`,
// the AWS_IAM additional auth provider). For these fields we append the IAM arm:
//   @aws_cognito_user_pools(cognito_groups: [...]) @aws_iam
// The Cognito arm preserves the field's existing group gating (or, when the
// field carries no Cognito group restriction, a bare `@aws_cognito_user_pools`
// keeps it open to any authenticated Cognito user); the `@aws_iam` arm admits
// the system caller. IAM access must be constrained by the API resource policy
// and a least-privilege deploy-role policy — see
// `docs/guides/appsync-iam-system-caller.md`.

let _permissionToCognitoGroups = (
  permission: Reventless.Authorization.permission,
): option<array<string>> =>
  switch permission {
  | AllowGroups([]) => Some(["__deny_all__"])
  | AllowGroups(groups) => Some(groups)
  | DenyAll => Some(["__deny_all__"])
  | AllowAuthenticated | AllowAnonymous => None
  }

// Both directive forms are defined once in the runtime-pure AppSync_SdlDecorate
// so this deploy path and the bundled AdminEventCollector Lambda's reactive push
// cannot drift. The Cognito-only arm carries the rationale for why it is
// `@aws_cognito_user_pools(...)` and never `@aws_auth(...)`.
let _formatGroupsDirective = AppSync_SdlDecorate.formatCognitoGroupsDirective

// Multi-auth directive for a field that must accept BOTH Cognito and IAM.
// `groups=Some([...])` preserves Cognito group gating; `groups=None` keeps the
// field open to any authenticated Cognito user. `@aws_iam` admits the
// deploy-time SigV4 system caller. See the dual-auth note above.
let _formatDualAuthDirective = AppSync_SdlDecorate.formatDualAuthDirective

// ── Type-level dual-auth ─────────────────────────────────────────────────────
// On a multi-auth API, object TYPES without auth directives are accessible only
// via the default auth mode — a field-level `@aws_iam` admits the system caller
// to the top-level field, but response shaping then walks the return types
// (`…Connection` → `…Edge` → node type → nested state types) and dies with
// "Not Authorized to access <field> on type <T>" one level in. Types reachable
// from a systemCallable field therefore carry the bare multi-auth pair: the
// group-less Cognito arm matches the pre-existing accessibility of an
// undirectived type (any authenticated user; entry gating stays on the fields),
// the IAM arm admits the traversal. Only `type` declarations take auth
// directives (inputs/enums/interfaces do not).

// The declared name of a `type …` SDL declaration; None for input/enum/union/etc.
let _typeDeclName = (decl: string): option<string> =>
  if decl->String.startsWith("type ") {
    let rest = decl->String.slice(~start=5, ~end=decl->String.length)
    let end = switch rest->String.search(%re("/[\s{]/")) {
    | -1 => rest->String.length
    | i => i
    }
    Some(rest->String.slice(~start=0, ~end))
  } else {
    None
  }

// Insert the multi-auth pair into a type declaration header (before its `{`).
let _stampTypeDualAuth = (decl: string): string =>
  switch decl->String.indexOfOpt("{") {
  | Some(i) =>
    decl->String.slice(~start=0, ~end=i) ++
    "@aws_cognito_user_pools @aws_iam " ++
    decl->String.slice(~start=i, ~end=decl->String.length)
  | None => decl
  }

// Shared traversal types every callable surface reaches — `PageInfo` (relay
// connections, injected by the stitcher) and the `CommandResult` members
// (mutation returns, deduped across fragments by the stitcher). They must be
// stamped exactly once on the ASSEMBLED SDL: stamping per-fragment would race
// the stitcher's first-wins dedupe against unstamped copies from sibling
// fragments. Unconditional — the API always configures AWS_IAM as an
// additional provider, so the directive is always valid.
// Canonical definition lives in the runtime-pure AppSync_SdlDecorate so the
// bundled AdminEventCollector Lambda's reactive push decorates identically.
let stampSharedIamTypes = AppSync_SdlDecorate.stampSharedIamTypes

let injectAwsAuth = (
  fragment: Reventless.Plugin.apiSchemaFragment,
  ~mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  ~queryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
): Reventless.Plugin.apiSchemaFragment => {
  let parts = ReventlessCore.GraphQL_Stitcher.decode(fragment)

  // Build authorization lookup from mutation entries: fieldName -> groups.
  // Spec-level `fieldPermissions` takes precedence over the legacy
  // `authorization.group` per-entry single-group form.
  // Fields opted into deploy-time IAM invocation (dual-auth). Membership here
  // switches a field from the single-mode `@aws_auth` form to the multi-auth
  // `@aws_cognito_user_pools(...) @aws_iam` form. Query entries mark by PREFIX
  // (single/list field name) because the generator derives further fields from
  // them — `…Items` (sub-id), `…ByIds`, `…By<Index>` (GSI) — which a system
  // caller (reconcile reads) uses too. Type declarations reachable from a
  // callable entry are stamped by returnTypeName prefix (see the type-level
  // dual-auth note above).
  let iamFields: Dict.t<bool> = Dict.make()
  let iamQueryFieldPrefixes: array<string> = []
  let iamTypePrefixes: array<string> = []

  let mutationAuthMap: Dict.t<array<string>> = Dict.make()
  mutationEntries->Array.forEach(entry => {
    if entry.systemCallable->Option.getOr(false) {
      entry.fieldNames->Array.forEach(fieldName => iamFields->Dict.set(fieldName, true))
    }
    switch entry.authorization {
    | Some({group}) =>
      entry.fieldNames->Array.forEach(fieldName =>
        mutationAuthMap->Dict.set(fieldName, [group])
      )
    | None => ()
    }
    switch entry.fieldPermissions {
    | Some(fp) =>
      fp
      ->Dict.toArray
      ->Array.forEach(((fieldName, permission)) => {
        switch _permissionToCognitoGroups(permission) {
        | Some(groups) => mutationAuthMap->Dict.set(fieldName, groups)
        | None => mutationAuthMap->Dict.delete(fieldName)
        }
      })
    | None => ()
    }
  })

  // Build authorization lookup from query entries: fieldName -> groups.
  // Spec-level `permission` takes precedence over the legacy authorization.
  let queryAuthMap: Dict.t<array<string>> = Dict.make()
  queryEntries->Array.forEach(entry => {
    if entry.systemCallable->Option.getOr(false) {
      iamFields->Dict.set(entry.singleFieldName, true)
      iamFields->Dict.set(entry.listFieldName, true)
      iamQueryFieldPrefixes->Array.push(entry.singleFieldName)
      iamQueryFieldPrefixes->Array.push(entry.listFieldName)
      iamTypePrefixes->Array.push(entry.returnTypeName)
    }
    switch entry.authorization {
    | Some({group}) =>
      queryAuthMap->Dict.set(entry.singleFieldName, [group])
      queryAuthMap->Dict.set(entry.listFieldName, [group])
    | None => ()
    }
    switch entry.permission {
    | Some(permission) =>
      switch _permissionToCognitoGroups(permission) {
      | Some(groups) =>
        queryAuthMap->Dict.set(entry.singleFieldName, groups)
        queryAuthMap->Dict.set(entry.listFieldName, groups)
      | None =>
        queryAuthMap->Dict.delete(entry.singleFieldName)
        queryAuthMap->Dict.delete(entry.listFieldName)
      }
    | None => ()
    }
  })

  // A field with no group restriction gets the group-less Cognito directive
  // rather than no directive at all. Same reachability under `defaultAction:
  // ALLOW`; the difference only shows once the default is DENY, where an
  // unstamped field is refused. See AppSync_SdlDecorate.cognitoOpenDirective.
  let openDirective = AppSync_SdlDecorate.cognitoOpenDirective

  let augmentedMutations = parts.mutations->Array.map(field => {
    let fieldName = ReventlessCore.GraphQL_Stitcher.extractLeadingName(field)
    let groups = mutationAuthMap->Dict.get(fieldName)
    if iamFields->Dict.get(fieldName)->Option.getOr(false) {
      `${field}\n    ${_formatDualAuthDirective(groups)}`
    } else {
      switch groups {
      | Some(groups) => `${field}\n    ${_formatGroupsDirective(groups)}`
      | None => `${field}\n    ${openDirective}`
      }
    }
  })

  let augmentedQueries = parts.queries->Array.map(field => {
    let fieldName = ReventlessCore.GraphQL_Stitcher.extractLeadingName(field)
    let groups = queryAuthMap->Dict.get(fieldName)
    let isIam =
      iamFields->Dict.get(fieldName)->Option.getOr(false) ||
        iamQueryFieldPrefixes->Array.some(p => fieldName->String.startsWith(p))
    if isIam {
      `${field} ${_formatDualAuthDirective(groups)}`
    } else {
      switch groups {
      | Some(groups) => `${field} ${_formatGroupsDirective(groups)}`
      | None => `${field} ${openDirective}`
      }
    }
  })

  // Subscriptions carried no directive at all on this path — they are reads and
  // need one for the same reason queries do. A subscription is never IAM-marked
  // (the deploy caller does not subscribe), so it takes the Cognito arm only:
  // the mutation's groups where the subscribed field has them, otherwise open.
  let augmentedSubscriptions = parts.subscriptions->Array.map(field => {
    let fieldName = ReventlessCore.GraphQL_Stitcher.extractLeadingName(field)
    switch mutationAuthMap->Dict.get(fieldName) {
    | Some(groups) => `${field}\n    ${_formatGroupsDirective(groups)}`
    | None => `${field}\n    ${openDirective}`
    }
  })

  // Type-level dual-auth for every type the callable entries' responses reach —
  // the node type, its Connection/Edge wrappers, and nested state types all
  // share the entry's returnTypeName prefix.
  let augmentedTypes = parts.types->Array.map(decl =>
    switch _typeDeclName(decl) {
    | Some(name) if iamTypePrefixes->Array.some(p => name->String.startsWith(p)) =>
      _stampTypeDualAuth(decl)
    | _ => decl
    }
  )

  ReventlessCore.GraphQL_Stitcher.encode({
    ...parts,
    types: augmentedTypes,
    mutations: augmentedMutations,
    queries: augmentedQueries,
    subscriptions: augmentedSubscriptions,
  })
}

// Injects @aws_auth with the given group on ALL mutation, query, and subscription
// fields in a fragment. Used for the base fragment where all fields share the
// same authorization group.
//
// `~iamFieldNames` opts the named mutation/query fields into deploy-time IAM
// (dual-auth): those fields emit `@aws_cognito_user_pools(cognito_groups:
// ["<group>"]) @aws_iam` instead of the single-mode `@aws_auth(...)`, keeping
// the same Cognito group gating while also admitting the SigV4 system caller.
// Subscriptions are never IAM-marked (the deploy caller does not subscribe).
// Canonical definition lives in the runtime-pure AppSync_SdlDecorate so the
// bundled AdminEventCollector Lambda's reactive push decorates the admin base
// identically to this deploy path. Eta-expanded to preserve the optional arg.
let injectAwsAuthAll = (
  fragment: Reventless.Plugin.apiSchemaFragment,
  ~group: string,
  ~iamFieldNames: array<string>=[],
): Reventless.Plugin.apiSchemaFragment =>
  AppSync_SdlDecorate.injectAwsAuthAll(fragment, ~group, ~iamFieldNames)

/**
One source-API document rendered standalone (relay base types included; the
global `node` query is not emitted on AWS — see the merged-api plan's "Relay
node resolution" section), decorated with the AppSync dialect:
`@aws_subscribe` on mutation-sourced subscription fields (from the fragment's
neutral `subscriptionSources` metadata) and `@aws_cognito_user_pools @aws_iam`
on the shared traversal types. Every AWS source-API document — the platform's
canonical documents and each plugin's subgraph — assembles through here so the
dialect is applied uniformly. No `@canonical` stamps here — the platform adds
them to its canonical documents only; plugin subgraphs stay unstamped and the
canonical definitions win on merge.
*/
let stitchStandaloneWithAwsDirectives = (
  ~fragment: Reventless.Plugin.apiSchemaFragment,
): string => {
  let sources = ReventlessCore.GraphQL_Stitcher.collectSubscriptionSources(
    ~baseFragment=fragment,
    ~pluginFragments=[],
  )
  // Every AWS source-API document assembles through here, so this is the one
  // place that can guarantee no field or type reaches a deployed schema without
  // an auth directive — whichever path injected it.
  let fragment = AppSync_SdlDecorate.stampUndirectivedFields(fragment)
  ReventlessCore.GraphQL_Stitcher.stitchStandalone(~fragment)
  ->AppSync_SdlDecorate.injectAwsSubscribe(~sources)
  ->stampSharedIamTypes
  // Last: every remaining undirectived type takes the group-less Cognito arm.
  // After stampSharedIamTypes so the shared traversal types keep `@aws_iam`.
  ->AppSync_SdlDecorate.stampAllTypesCognito
}

// ── Provider implementation ────────────────────────────────────────────────

type api = AppSync.GraphQLApi.t
type role = IAM.Role.t

// Primary authentication mode every platform-created AppSync API uses. A
// merged API and its source APIs must share this primary mode — exported via
// StackReference (`mergedApiPrimaryAuth`) and asserted where associations are
// created (AppSync_MergedApi.assertCompatiblePrimaryAuth).
let primaryAuthenticationType = AppSync.GraphQLApi.AMAZON_COGNITO_USER_POOLS

let _makeApiResourceWith = (
  ~name: string,
  ~schema: option<string>,
  ~userPoolConfig: option<Pulumi.Output.t<AppSync.GraphQLApi.userPoolConfig>>,
  ~opts: Pulumi.ComponentResource.options,
): (Pulumi.Output.t<api>, Pulumi.Output.t<role>) => {
  let customOpts: Pulumi.CustomResourceOptions.t = {
    parent: ?opts.parent,
  }

  // Create IAM role for AppSync
  let iamRole = IAM.Role.make(
    ~name=`${name}-appsync-role`,
    ~args={
      assumeRolePolicy: `{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"appsync.amazonaws.com"},"Action":"sts:AssumeRole"}]}`
        ->Pulumi.Input.make,
      tags: AWS.Tags.make(
        ~name=`${name}-appsync-role`,
        ~kind=ReventlessCore.ComponentType.Platform,
        ~role=Identity,
        ~scope=Platform,
      ),
    },
    ~opts=Some(customOpts),
  )

  // Let AppSync push field-resolver errors to CloudWatch. The API's own service
  // role is already assumable by appsync.amazonaws.com, so attach the AWS-managed
  // push policy to it and reuse it as the logging role. `fieldLogLevel = ERROR`
  // (below) then captures resolver failures AppSync otherwise swallows into the
  // client's `errors[]` — e.g. a non-null coercion on a stale read-model row.
  let _appsyncCwLogsAttachment = IAM.RolePolicyAttachment.make(
    ~name=`${name}-appsync-cwlogs`,
    ~args={
      role: iamRole.name->Pulumi.Output.asInput,
      policyArn: "arn:aws:iam::aws:policy/service-role/AWSAppSyncPushToCloudWatchLogs"->Pulumi.Input.make,
    },
    ~opts=Some(customOpts),
  )
  let appsyncLogConfig: AppSync.GraphQLApi.logConfig = {
    cloudwatchLogsRoleArn: iamRole.arn->Pulumi.Output.asInput,
    fieldLogLevel: AppSync.GraphQLApi.ERROR->Pulumi.Input.make,
  }

  // Resolve the Cognito UserPool — either supplied by the caller (plugin-stack
  // source APIs read it from the platform's StackReference exports so they
  // never provision pool/client resources of their own) or resolved via
  // Auth_Cognito (cached inside Platform_Stack, so calling from each API call
  // site — DomainApi, PlatformApi — is safe). A single Output yielding the
  // {userPoolId, awsRegion, defaultAction} record AppSync expects.
  //
  // `DENY`, not `ALLOW`: an undirectived field or type is refused rather than
  // served to any authenticated Cognito caller. This is what makes a missing
  // directive fail closed — under `ALLOW` the group gate that was inert for the
  // whole of `@aws_auth`'s life produced no symptom at all, because "no
  // effective directive" and "open to everyone" were the same thing.
  //
  // Safe only because every field and type now carries an explicit directive
  // (`stampUndirectivedFields` + `stampAllTypesCognito` at the assembly choke
  // point). Verify with `scripts/check-appsync-directive-coverage.mjs` against a
  // DEPLOYED api — it must report zero before this value is trusted.
  let userPoolConfigOut = switch userPoolConfig {
  | Some(config) => config
  | None =>
    Auth_Cognito.make(~name=`${name}-auth`)->Pulumi.Output.apply((c: Auth_Cognito.authConfig) =>
      (
        {
          userPoolId: c.userPoolId,
          awsRegion: c.region,
          defaultAction: AppSync.GraphQLApi.DENY,
        }: AppSync.GraphQLApi.userPoolConfig
      )
    )
  }

  // Cognito as primary auth, AWS_IAM as additional provider for
  // server-to-server lambdas (heartbeat, Plugin_Connected emission) signed via
  // the existing IAM role.
  let apiArgs: AppSync.GraphQLApi.args = {
    authenticationType: primaryAuthenticationType->Pulumi.Input.make,
    userPoolConfig: userPoolConfigOut->Pulumi.Output.asInput,
    additionalAuthenticationProviders: [
      (
        {
          authenticationType: AppSync.GraphQLApi.AWS_IAM->Pulumi.Input.make,
        }: AppSync.GraphQLApi.additionalAuthenticationProvider
      )->Pulumi.Input.make,
    ]->Pulumi.Input.make,
    schema: ?(schema->Option.map(Pulumi.Input.make)),
    logConfig: appsyncLogConfig->Pulumi.Input.make,
    tags: AWS.Tags.make(
      ~name,
      ~kind=ReventlessCore.ComponentType.Plugin,
      ~role=Api,
      ~scope=Plugin,
    ),
  }
  let graphQLApi = AppSync.GraphQLApi.make(~name, ~args=apiArgs, ~opts=Some(customOpts))

  // Managed log group with tiered retention for AppSync's own field-resolver logs,
  // which land in `/aws/appsync/apis/<id>` and otherwise live forever with no
  // retention. Managed on every stack by default (bar any in
  // `unmanagedLogGroupStacks`), same as the Lambda groups.
  //
  // Unlike a Lambda's group this one cannot be created ahead of the resource that
  // writes to it: the name comes from the API's server-assigned id, so the group
  // is always second and any request the API serves in between creates it first.
  // `Util_LogGroup_Adopting` is what makes losing that order survivable — it
  // adopts an existing group rather than failing `ResourceAlreadyExists`.
  let stack = Pulumi.Pulumi.getStackName()
  let prodStacks = Util_HostUiDomain.resolveProdStacks()
  let unmanagedStacks = Util_LogRetention.parseUnmanagedStacks(
    Util_LocalConfig.get("unmanagedLogGroupStacks")->Option.getOr(""),
  )
  if Util_LogRetention.managesLogGroup(~stack, ~unmanagedStacks) {
    let _ = Util_LogGroup_Adopting.make(
      ~name=`${name}AppSyncLogGroup`,
      ~props={
        logGroupName: graphQLApi.id
        ->Pulumi.Output.apply(id => `/aws/appsync/apis/${id}`)
        ->Pulumi.Output.asInput,
        retentionInDays: Util_LogRetention.retentionDaysFor(
          ~stack,
          ~prodStacks,
          ~configOverride=?Util_LocalConfig.get("logRetentionDays")->Option.flatMap(s =>
            Int.fromString(s)
          ),
        )->Pulumi.Input.make,
        tags: AWS.Tags.makeDict(
          ~name=`${name}AppSyncLogGroup`,
          ~kind=ReventlessCore.ComponentType.Plugin,
          ~role=Logs,
          ~scope=Plugin,
        )->Pulumi.Input.make,
      },
      ~opts=Some(customOpts),
    )
  }

  (graphQLApi->Pulumi.Output.make, iamRole->Pulumi.Output.make)
}

let makeApiResource = (
  ~name: string,
  ~opts: Pulumi.ComponentResource.options,
): (Pulumi.Output.t<api>, Pulumi.Output.t<role>) =>
  _makeApiResourceWith(~name, ~schema=None, ~userPoolConfig=None, ~opts)

// Merged-mode source API: same auth shape as makeApiResource but with a
// DECLARATIVE inline schema — the provider runs StartSchemaCreation + poll
// before the resource resolves, so resolvers chained on the API are ordered
// after the schema is ACTIVE without the push-path hook machinery. Not part
// of the Api_Adapter.Provider interface (Platform.res calls it directly on
// the merge path).
let makeSourceApiResource = (
  ~name: string,
  ~schema: string,
  ~opts: Pulumi.ComponentResource.options,
): (Pulumi.Output.t<api>, Pulumi.Output.t<role>) =>
  _makeApiResourceWith(~name, ~schema=Some(schema), ~userPoolConfig=None, ~opts)

// Merged-mode PLUGIN source API: schema-less at creation (the plugin's
// standalone subgraph document is only computable during P.make(), so
// preResolversSchemaHook pushes it — the plugin's own API is a single writer
// by construction). The user pool comes from the platform's StackReference
// exports so the merged endpoint's Cognito primary auth matches across every
// source API without the plugin stack provisioning pool/client resources.
let makePluginSourceApiResource = (
  ~name: string,
  ~userPoolConfig: Pulumi.Output.t<AppSync.GraphQLApi.userPoolConfig>,
  ~opts: Pulumi.ComponentResource.options,
): (Pulumi.Output.t<api>, Pulumi.Output.t<role>) =>
  _makeApiResourceWith(~name, ~schema=None, ~userPoolConfig=Some(userPoolConfig), ~opts)

let generateFragment = (
  ~mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  ~queryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
): Reventless.Plugin.apiSchemaFragment => {
  let fragment = ReventlessCore.GraphQL_FragmentGenerator.generate(~mutationEntries, ~queryEntries)
  injectAwsAuth(fragment, ~mutationEntries, ~queryEntries)
}

// (updateSchema — the whole-replace stitched-schema push — was retired with
// the merged-API cutover; every source API owns its schema declaratively or
// via its own single-writer subgraph push in preResolversSchemaHook.)
