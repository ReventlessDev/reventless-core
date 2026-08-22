// The role a caller chose to act as, as server-side state — and the one door
// that writes it. See [docs/plans/active-role-narrows-the-token.md] §6.
//
// Why state rather than a parameter on the token request: Cognito "doesn't
// include data from the ClientMetadata parameter in AdminInitiateAuth and
// InitiateAuth API operations in the request that it passes to the pre token
// generation function", and a role switch is a `REFRESH_TOKEN_AUTH` flow — an
// `InitiateAuth` one. The channel that looks purpose-built for carrying the
// choice is closed on exactly the path that needs it, so the choice is stored
// here and the trigger reads it on the next refresh.
//
// Why not a `custom:activeRole` attribute on the user, which was the first
// design: a Cognito custom attribute is a one-way door — it can never be removed
// or retyped once added to a pool. A table avoids permanently amending a
// customer's user pool to hold a preference.
//
// Split in two because the pieces are needed at different points in the deploy
// graph, and the order is forced rather than chosen:
//
//   makeTable      the rows. Depends on nothing.
//   ↓
//   trigger        needs the table to read from ([Auth_ActiveRoleTrigger.res])
//   ↓
//   user pool      needs the trigger's ARN as `lambdaConfig.preTokenGeneration`
//   ↓
//   GraphQL API    needs the pool as its authorizer
//   ↓
//   makeWriteDoor  needs the API to hang a resolver on, and the table to write
//
// Provisioning the table with the write door instead would close that chain into
// a cycle, so the table is hoisted to where the pool is resolved.
//
// 🚨 **The rows follow the identity provider, not the stack** — see
// [ReventlessCore.Auth_ActiveRole] for the contract and
// [docs/plans/active-role-store-scoped-to-the-pool.md] for the defect that
// produced it. A pool holds one pre-token-generation trigger, so two stacks
// sharing a pool with a table each have the winning trigger reading rows the
// serving resolver never wrote: every switch succeeds and does nothing.
//
// So there are two cases and no third. A stack that creates its own pool owns
// everything attached to it, this table included. A stack handed an
// `identityProviderId` owns none of it: the pool exists outside every stack, and
// so does the store, at the name [derivedStoreName] gives. See [chooseStore].

open PulumiAws

type storeTable = {
  name: Pulumi.Output.t<string>,
  arn: Pulumi.Output.t<string>,
}

/** Which store a deployment's trigger reads and its write door writes. */
type storeChoice =
  /** The stack creates and owns the table, because it also creates and owns the
    pool: nothing else can be attached to that pool, so there is nothing to
    share. */
  | StackScoped
  /** The provider's own store, looked up at [derivedStoreName] and never created.
    Every stack on that provider resolves the same table. */
  | ProviderScoped(string)

/**
The store a resolved provider calls for.

Total and pure, so the rule is checkable without a stack — and total is the point:
there is no configuration here that can be wrong, because there is no second key
to disagree with the first. Whether the provider is ours decides the store, and
nothing else is consulted.
*/
let chooseStore = (~identityProviderId: option<string>): storeChoice =>
  switch identityProviderId {
  | None => StackScoped
  | Some(id) =>
    ProviderScoped(Auth_ActiveRoleStore_Schema.derivedStoreName(~identityProviderId=id))
  }

// JS resolver code (APPSYNC_JS runtime): forward the caller's arguments and the
// authorizer-verified identity. `sub` is what keys the row, and it comes from
// here — the mutation has no `sub` argument for a client to supply.
//
// `username` travels with it because the two answer different questions. The row
// is keyed on `sub`, which is stable across a rename and is what the pre-token
// trigger looks the row up by; but Cognito's admin API addresses a user by
// *username*, and a pool with neither `UsernameAttributes` nor `AliasAttributes`
// does not accept a `sub` there — it answers `UserNotFoundException`, which is
// how the membership read used to fail for every caller on such a pool. Both
// fields come from the authorizer, so forwarding the second grants nothing the
// first did not.
//
// 🚨 **`clientId` completes the row key, and it comes from the token's own
// claims** — `aud` on an ID token, `client_id` on an access token, since AppSync
// accepts either. It is what makes the active role per-platform on a provider
// serving several. `aud` is a string on a Cognito ID token but an array in OIDC
// generally, so the first element is taken rather than assuming.
//
// Forwarded as `null` when the claims are not there to read: the handler refuses
// rather than inventing a key. A guessed client id would write a row under one
// key that the trigger reads under another — the very defect this feature was
// repaired for, rebuilt one level down.
let invokeCode: Pulumi.Input.t<string> = `import { util } from '@aws-appsync/utils';
function appClientId(id) {
  const claims = id.claims;
  if (claims == null) return null;
  const aud = claims.aud;
  const picked = Array.isArray(aud) ? aud[0] : aud;
  const value = picked ?? claims.client_id;
  return typeof value === 'string' && value !== '' ? value : null;
}
export function request(ctx) {
  const id = ctx.identity;
  return {
    operation: 'Invoke',
    payload: {
      arguments: ctx.args,
      identity: id != null && id.sub != null
        ? { sub: id.sub, username: id.username ?? null, clientId: appClientId(id) }
        : null
    }
  };
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
`->Pulumi.Input.make

/** One row per (subject, app client) — the key schema is
  [Auth_ActiveRoleStore_Schema]'s, shared with both handlers and the provisioning
  script — plus `activeRole`, the group they chose, and `updatedAt`, an
  operational breadcrumb. A caller acts as exactly one role at a time *per
  platform*, so the row is the whole state. */
let makeTable = (
  ~name: string="ActiveRoleStore",
  ~opts: Pulumi.ComponentResource.options,
): storeTable => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions
  let table = Util_DynamoDb.makeTable(
    ~attributes=[
      {name: Auth_ActiveRoleStore_Schema.partitionKey, type_: "S"},
      {name: Auth_ActiveRoleStore_Schema.sortKey, type_: "S"},
    ],
    ~rangeKey=Auth_ActiveRoleStore_Schema.sortKey,
    ~tags=AWS.Tags.make(
      ~name=name ++ "Table",
      ~kind=ReventlessCore.ComponentType.Platform,
      ~role=Auth,
      ~scope=Platform,
    ),
    ~opts,
    name,
  )
  {name: table.name, arn: table.arn}
}

/** The [ProviderScoped] table: looked up, never created.

  Looked up for the same reason a BYO pool is — the operator owns the identity,
  and these rows are part of that identity's state. Creating it here would put
  every stack on the provider in a race to own one resource.

  A name that resolves to nothing fails the deploy, which is the second half of
  "the provider and its store must both exist". The failure names the table it
  looked for, which is also the table the provisioning script creates. */
let lookupTable = (~tableName: string): storeTable => {
  let found = DynamoDb.Table.Get.output(~args={name: tableName})
  {
    name: found->Pulumi.Output.apply(t => t.name),
    arn: found->Pulumi.Output.apply(t => t.arn),
  }
}

/** The store a resolved provider calls for — created or looked up. */
let resolveTable = (~choice: storeChoice, ~opts: Pulumi.ComponentResource.options): storeTable =>
  switch choice {
  | StackScoped => makeTable(~opts)
  | ProviderScoped(tableName) => lookupTable(~tableName)
  }

/** The Lambda behind `Mutation.Platform_SetActiveRole` and its resolver: an
  execution role scoped to Logs + the one table + `AdminListGroupsForUser` on the
  one pool, an AppSync Lambda data source, and the resolver itself. */
let makeWriteDoor = (
  ~api: Pulumi.Output.t<AppSync.GraphQLApi.t>,
  ~table: storeTable,
  ~cognitoUserPoolId: Pulumi.Input.t<string>,
  ~cognitoUserPoolArn: Pulumi.Input.t<string>,
  ~name: string="ActiveRoleStore",
  ~opts: Pulumi.ComponentResource.options,
): unit => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let lambdaRole = IAM.Role.makeWithDefaultPolicy(
    ~name=name ++ "Lambda",
    ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
    ~tags=AWS.Tags.make(
      ~name=name ++ "Lambda",
      ~kind=ReventlessCore.ComponentType.Platform,
      ~role=Identity,
      ~scope=Platform,
    ),
    ~opts,
  )

  // Logs, the one table, and group membership on the one pool.
  //
  // `AdminListGroupsForUser` is what makes the refusal in the handler real: a
  // narrowed token carries a single group, so membership has to come from
  // Cognito rather than from the token, or a caller who narrowed once could
  // never widen back. Scoped to this pool's ARN, and it is a read — this role
  // cannot add anyone to a group, only observe who is in one.
  let _policy =
    (table.arn, cognitoUserPoolArn->Pulumi.Output.fromInput)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((tableArn, poolArn)) => {
      let _ = IAM.RolePolicy.make(
        ~name=name ++ "LambdaPolicy",
        ~args={
          policy: PolicyDocument.make(
            ~id=name ++ "LambdaPolicy",
            ~statements=[
              {
                sid: "AllowLambdaLogging",
                effect: Allow,
                actions: Actions([
                  "logs:CreateLogGroup",
                  "logs:CreateLogStream",
                  "logs:PutLogEvents",
                ]),
                resources: Resource("arn:aws:logs:*:*:*"),
              },
              {
                sid: "AllowActiveRoleRowAccess",
                effect: Allow,
                actions: Actions(["dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:GetItem"]),
                resources: Resource(tableArn),
              },
              {
                sid: "AllowReadingOwnPoolMembership",
                effect: Allow,
                actions: Action("cognito-idp:AdminListGroupsForUser"),
                resources: Resource(poolArn),
              },
            ],
          )
          ->PolicyDocument.toJsonString
          ->Pulumi.Input.make,
          role: lambdaRole.id->Pulumi.Output.asInput,
        },
        ~opts,
      )
    })

  let packageDirs = Dict.fromArray([
    (
      "@reventlessdev/reventless-aws",
      Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-aws"),
    ),
  ])
  let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
    ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Auth/Auth_ActiveRoleStore_Ops.res.mjs",
    ~packageDirs,
    ~bundleRuntimeExtensions=false,
  )

  let layers =
    Lambda.reventlessLayerArn
    ->Option.map(arn => [arn->Pulumi.Input.make])
    ->Option.getOr([])
    ->Pulumi.Input.make

  let logGroup = Util_LambdaLogging.makeManagedLogGroup(
    ~name=name ++ "Lambda",
    ~tags=AWS.Tags.make(
      ~name=name ++ "LambdaLogGroup",
      ~kind=ReventlessCore.ComponentType.Platform,
      ~role=Logs,
      ~scope=Platform,
    ),
    ~opts,
    (),
  )

  let lambda = Lambda.Function.make(
    ~name=name ++ "Lambda",
    ~args={
      handler: "index.handler"->Pulumi.Input.make,
      runtime: "nodejs22.x"->Pulumi.Input.make,
      code: code->Pulumi.Input.make,
      sourceCodeHash: sourceCodeHash->Pulumi.Input.make,
      role: lambdaRole.arn->Pulumi.Output.asInput,
      memorySize: 256->Pulumi.Input.make,
      timeout: 30->Pulumi.Input.make,
      layers,
      tags: AWS.Tags.make(
        ~name=name ++ "Lambda",
        ~kind=ReventlessCore.ComponentType.Platform,
        ~role=Runtime,
        ~scope=Platform,
      ),
      environment: (
        {
          Lambda.Function.variables: Dict.fromArray([
            ("Environment", Pulumi.Pulumi.getStackName()->Pulumi.Input.make),
            ("ACTIVE_ROLE_TABLE", table.name->Pulumi.Output.asInput),
            ("COGNITO_USER_POOL_ID", cognitoUserPoolId),
            ("NODE_OPTIONS", Util_Bundle.esmLoaderNodeOptions->Pulumi.Input.make),
            ("ESM_FALLBACK_DIRS", Util_Bundle.esmFallbackDirs->Pulumi.Input.make),
            Util_LambdaLogging.logLevelEntry(),
          ]),
        }: Lambda.Function.functionEnvironment
      )->Pulumi.Input.make,
      loggingConfig: ?Util_LambdaLogging.loggingConfigFor(logGroup),
    },
    ~opts,
  )

  let dataSourceRole = IAM.Role.makeWithDefaultPolicy(
    ~name=name ++ "DataSource",
    ~servicePrincipal=AWS.AppSync.principal->Pulumi.Output.make,
    ~tags=AWS.Tags.make(
      ~name=name ++ "DataSource",
      ~kind=ReventlessCore.ComponentType.Platform,
      ~role=Identity,
      ~scope=Platform,
    ),
    ~opts,
  )

  let _ =
    (lambda.arn, dataSourceRole.id)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((lambdaArn, dataSourceRoleId)) => {
      let _attach = IAM.RolePolicy.make(
        ~name=name ++ "DataSource",
        ~args={
          policy: PolicyDocument.make(
            ~id=name ++ "DataSourcePolicy",
            ~statements=[
              {
                sid: "AllowDataSourceInvokeLambda",
                effect: Allow,
                actions: Action("lambda:InvokeFunction"),
                resources: Resource(lambdaArn),
              },
            ],
          )
          ->PolicyDocument.toJsonString
          ->Pulumi.Input.make,
          role: dataSourceRoleId->Pulumi.Input.make,
        },
        ~opts,
      )
    })

  let dataSource = AppSync.DataSource.make(
    ~name=name ++ "DataSource",
    ~args={
      type_: AWS_LAMBDA,
      apiId: api->Pulumi.Output.flatMap(api => api.id)->Pulumi.Output.asInput,
      lambdaConfig: {
        AppSync.DataSource.functionArn: lambda.arn->Pulumi.Output.asInput,
      }->Pulumi.Input.make,
      serviceRoleArn: dataSourceRole.arn->Pulumi.Output.asInput,
    },
    ~opts=Some(opts),
  )

  let _resolver = AppSync_Resolver_Native.makeUnitJsResolver(
    ~name=name ++ "SetActiveRole",
    ~api,
    ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
    ~type_="Mutation"->Pulumi.Input.make,
    ~field="Platform_SetActiveRole"->Pulumi.Input.make,
    ~code=invokeCode,
    ~opts,
  )
}
