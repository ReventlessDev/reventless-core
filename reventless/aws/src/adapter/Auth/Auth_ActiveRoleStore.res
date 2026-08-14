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

open PulumiAws

type storeTable = {
  name: Pulumi.Output.t<string>,
  arn: Pulumi.Output.t<string>,
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
let invokeCode: Pulumi.Input.t<string> = `import { util } from '@aws-appsync/utils';
export function request(ctx) {
  const id = ctx.identity;
  return {
    operation: 'Invoke',
    payload: {
      arguments: ctx.args,
      identity: id != null && id.sub != null ? { sub: id.sub, username: id.username ?? null } : null
    }
  };
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
`->Pulumi.Input.make

/** One row per subject: `id` is the caller's Cognito `sub`, `activeRole` the
  group they chose, `updatedAt` an operational breadcrumb. No sort key — a caller
  acts as exactly one role at a time, so the row is the whole state. */
let makeTable = (
  ~name: string="ActiveRoleStore",
  ~opts: Pulumi.ComponentResource.options,
): storeTable => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions
  let table = Util_DynamoDb.makeTable(
    ~attributes=[{name: "id", type_: "S"}],
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
