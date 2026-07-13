// AppSync_Adapter — implements ReventlessInfra.Api_Adapter.Provider for AWS AppSync.
//
// Creates a new AppSync GraphQL API and IAM execution role.
// updateSchema uses the AWS AppSync SDK to push a stitched SDL whenever plugins connect.

open PulumiAws

let log = ReventlessCore.Logger.fromEnv()

// ── SHA-256 helper ─────────────────────────────────────────────────────────

type hashObject
@module("node:crypto") external createHash: string => hashObject = "createHash"
@send external hashUpdate: (hashObject, string) => hashObject = "update"
@send external hashDigest: (hashObject, string) => string = "digest"

let sha256Hex = (input: string): string =>
  createHash("sha256")->hashUpdate(input)->hashDigest("hex")

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

// GetIntrospectionSchema — fetch the live schema as an SDL string. Used by the
// deploy-time drift check in preResolversSchemaHook to detect a live schema that
// was clobbered out-of-band by a runtime re-stitch (the stored deploy hash does
// not reflect such clobbers). Returns "" when the API has no schema or when
// introspection fails — the caller decides how to treat an empty result.
type getIntrospectionSchemaInput = {apiId: string, format: string}
type getIntrospectionSchemaCommand
type schemaBlob
type getIntrospectionSchemaResult = {schema: option<schemaBlob>}

@module("@aws-sdk/client-appsync") @new
external makeGetIntrospectionSchemaCommand: getIntrospectionSchemaInput => getIntrospectionSchemaCommand =
  "GetIntrospectionSchemaCommand"

@send
external sendGetIntrospection: (
  appSyncClient,
  getIntrospectionSchemaCommand,
) => promise<getIntrospectionSchemaResult> = "send"

// resp.schema is a Uint8Array of the SDL text; decode it to UTF-8.
type nodeBuffer
@val @scope("Buffer") external bufferFrom: schemaBlob => nodeBuffer = "from"
@send external bufferToString: (nodeBuffer, string) => string = "toString"

let getIntrospectionSdl = async (client: appSyncClient, apiId: string): string => {
  try {
    let resp = await client->sendGetIntrospection(
      {apiId, format: "SDL"}->makeGetIntrospectionSchemaCommand,
    )
    switch resp.schema {
    | Some(blob) => bufferFrom(blob)->bufferToString("utf-8")
    | None => ""
    }
  } catch {
  | exn =>
    let msg = exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
    log.warn(~comp="AppSync_Adapter", `getIntrospectionSdl failed for ${apiId}: ${msg}`)
    ""
  }
}

let deploySchemaWithRetry = (
  client: appSyncClient,
  apiId: string,
  definition: string,
): Effect.t<unit, AppSync_Error.t, unit> =>
  Effect.tryPromise(
    ~catch=AppSync_Error.classify,
    () => startSchemaCreation(client, {apiId, definition})->Promise.then(_ => Promise.resolve()),
  )->Effect.retry(AppSync_Error.retrySchedule)

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

// ── @aws_auth directive injection ─────────────────────────────────────────
// Injects @aws_auth(cognito_groups: [...]) directives into SDL field strings
// based on authorization metadata from schema entries.
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
// `@aws_auth(cognito_groups: ["g1", "g2", ...])`. `AllowAuthenticated` /
// `AllowAnonymous` emit no directive (with Cognito as primary auth, any
// reaching request is already authenticated). `AllowGroups([])` and
// `DenyAll` emit a sentinel `__deny_all__` group that no Cognito user can
// belong to — effectively blocking the field at the API layer.
//
// ── Dual-auth (Cognito + IAM) for deploy-time system callers ────────────────
// A field flagged `systemCallable` (via `mutationSchemaEntry`/`querySchemaEntry`)
// must be reachable by BOTH the console UI (Cognito) and a deploy-time system
// caller signing SigV4 with ambient AWS credentials (`Util_AppSync_Caller`,
// the AWS_IAM additional auth provider). `@aws_auth(...)` is the single-mode
// directive form and does not admit IAM on a multi-auth API. For these fields
// we emit the multi-auth form instead:
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

let _formatGroupsDirective = (groups: array<string>): string => {
  let quoted = groups->Array.map(g => `"${g}"`)->Array.join(", ")
  `@aws_auth(cognito_groups: [${quoted}])`
}

// Multi-auth directive for a field that must accept BOTH Cognito and IAM.
// `groups=Some([...])` preserves Cognito group gating; `groups=None` keeps the
// field open to any authenticated Cognito user. `@aws_iam` admits the
// deploy-time SigV4 system caller. See the dual-auth note above.
let _formatDualAuthDirective = (groups: option<array<string>>): string => {
  let cognito = switch groups {
  | Some(g) =>
    let quoted = g->Array.map(x => `"${x}"`)->Array.join(", ")
    `@aws_cognito_user_pools(cognito_groups: [${quoted}])`
  | None => `@aws_cognito_user_pools`
  }
  `${cognito} @aws_iam`
}

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

  let augmentedMutations = parts.mutations->Array.map(field => {
    let fieldName = ReventlessCore.GraphQL_Stitcher.extractLeadingName(field)
    let groups = mutationAuthMap->Dict.get(fieldName)
    if iamFields->Dict.get(fieldName)->Option.getOr(false) {
      `${field}\n    ${_formatDualAuthDirective(groups)}`
    } else {
      switch groups {
      | Some(groups) => `${field}\n    ${_formatGroupsDirective(groups)}`
      | None => field
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
      | None => field
      }
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
Stitch base + plugin fragments and decorate the assembled SDL with the AppSync
dialect: `@aws_subscribe` on mutation-sourced subscription fields (from the
fragments' neutral `subscriptionSources` metadata — core no longer emits the
directive) and `@aws_cognito_user_pools @aws_iam` on the shared traversal
types. Every AWS schema push assembles its SDL through here so the dialect is
applied uniformly.
*/
let stitchWithAwsDirectives = (
  ~baseFragment: Reventless.Plugin.apiSchemaFragment,
  ~pluginFragments: array<Reventless.Plugin.apiSchemaFragment>,
): string => {
  let sources = ReventlessCore.GraphQL_Stitcher.collectSubscriptionSources(
    ~baseFragment,
    ~pluginFragments,
  )
  ReventlessCore.GraphQL_Stitcher.stitch(~baseFragment, ~pluginFragments)
  ->AppSync_SdlDecorate.injectAwsSubscribe(~sources)
  ->stampSharedIamTypes
}

// ── Provider implementation ────────────────────────────────────────────────

type api = AppSync.GraphQLApi.t
type role = IAM.Role.t

let makeApiResource = (
  ~name: string,
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
    },
    ~opts=Some(customOpts),
  )

  // Resolve the Cognito UserPool — cached inside Platform_Stack, so calling
  // from each API call site (DomainApi, PlatformApi) is safe. Returned as a
  // single Output that yields the {userPoolId, awsRegion, defaultAction}
  // record AppSync expects.
  let authConfigOut = Auth_Cognito.make(~name=`${name}-auth`)
  let userPoolConfigOut =
    authConfigOut->Pulumi.Output.apply((c: Auth_Cognito.authConfig) =>
      (
        {
          userPoolId: c.userPoolId,
          awsRegion: c.region,
          defaultAction: AppSync.GraphQLApi.ALLOW,
        }: AppSync.GraphQLApi.userPoolConfig
      )
    )

  // Cognito as primary auth, AWS_IAM as additional provider for
  // server-to-server lambdas (heartbeat, Plugin_Connected emission) signed via
  // the existing IAM role.
  let apiArgs: AppSync.GraphQLApi.args = {
    authenticationType: AppSync.GraphQLApi
    .AMAZON_COGNITO_USER_POOLS->Pulumi.Input.make,
    userPoolConfig: userPoolConfigOut->Pulumi.Output.asInput,
    additionalAuthenticationProviders: [
      (
        {
          authenticationType: AppSync.GraphQLApi.AWS_IAM->Pulumi.Input.make,
        }: AppSync.GraphQLApi.additionalAuthenticationProvider
      )->Pulumi.Input.make,
    ]->Pulumi.Input.make,
  }
  let graphQLApi = AppSync.GraphQLApi.make(~name, ~args=apiArgs, ~opts=Some(customOpts))

  (graphQLApi->Pulumi.Output.make, iamRole->Pulumi.Output.make)
}

let generateFragment = (
  ~mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  ~queryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
): Reventless.Plugin.apiSchemaFragment => {
  let fragment = ReventlessCore.GraphQL_FragmentGenerator.generate(~mutationEntries, ~queryEntries)
  injectAwsAuth(fragment, ~mutationEntries, ~queryEntries)
}

let updateSchema = (
  ~api: Pulumi.Output.t<api>,
  ~baseFragment: Reventless.Plugin.apiSchemaFragment,
  ~pluginFragments: array<Reventless.Plugin.apiSchemaFragment>,
): promise<unit> => {
  // Inject @aws_auth(cognito_groups: ["Admin"]) into all base fragment fields.
  // The base fragment contains core Plugin aggregate queries/mutations — all Admin-only.
  // Plugin fragments already have @aws_auth injected via generateFragment.
  let augmentedBaseFragment = injectAwsAuthAll(baseFragment, ~group="Admin")
  // Shared traversal types + @aws_subscribe are stamped once on the assembled
  // SDL (post-stitch, post-dedupe) — see stitchWithAwsDirectives.
  let sdl = stitchWithAwsDirectives(~baseFragment=augmentedBaseFragment, ~pluginFragments)
  // Resolve the API ID from the Output chain. In mock mode (tests) and in Lambda runtime
  // (where the Output is backed by already-known values), this completes synchronously.
  // The resulting promise wraps the AppSync SDK call.
  let resultPromise: ref<promise<unit>> = ref(Promise.resolve())
  let _ =
    api
    ->Pulumi.Output.apply(graphQLApi =>
      graphQLApi.id->Pulumi.Output.apply(apiId => {
        let effect = deploySchemaWithRetry(getClient(), apiId, sdl)
        let p = effect->Effect.runPromise
        resultPromise.contents = p
      })
    )
  resultPromise.contents
}
