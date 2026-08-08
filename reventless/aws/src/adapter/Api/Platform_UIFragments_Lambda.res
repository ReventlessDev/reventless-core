// AWS resolver for the `Platform_UIFragments` admin GraphQL query.
//
// Backed by a Lambda DataSource that scans the UiFragments StateViewSlice table
// (one item per plugin with a registered UI-fragment manifest).
// The persisted state is sury-encoded with the same shape the in-memory adapter's
// `Platform_UIFragmentsApi.encodeUIFragmentEntry` produces (null-encoded options,
// nested panel/page objects), so the handler simply returns the rows as-is.

open PulumiAws

let resolverCode = `
import { util } from '@aws-appsync/utils';
export function request(ctx) {
  return { operation: 'Invoke', payload: {} };
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
`->Pulumi.Input.make

let make = (
  ~api: Pulumi.Output.t<AppSync.GraphQLApi.t>,
  ~uiFragmentRegistryTableName: Pulumi.Output.t<string>,
  // Resolves when the admin-base schema push has completed and the API is ACTIVE
  // (Platform_Admin.adminSchemaPushed). CreateResolver is gated on it so it never
  // races StartSchemaCreation — the same first-deploy race that clobbered
  // Platform_ApiFragments; harmless here today only because the field predates it.
  ~schemaReady: Pulumi.Output.t<unit>,
  ~opts: Pulumi.ComponentResource.options,
) => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions
  let name = "PlatformUIFragments"

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

  let _ =
    uiFragmentRegistryTableName->Pulumi.Output.apply(tableName => {
      open PolicyDocument
      let _rolePolicy = IAM.RolePolicy.make(
        ~name=name ++ "LambdaPolicy",
        ~args={
          IAM.RolePolicy.policy: PolicyDocument.make(
            ~id=name ++ "LambdaPolicy",
            ~statements=[
              {
                sid: "AllowLambdaLogging",
                effect: Allow,
                actions: Action("logs:*"),
                resources: Resource("arn:aws:logs:*:*:*"),
              },
              {
                sid: "AllowScanUiFragmentsTable",
                effect: Allow,
                actions: Actions(["dynamodb:Scan"]),
                resources: Resource("arn:aws:dynamodb:*:*:table/" ++ tableName),
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

  // Bundle reventless-aws (the compiled `_Ops` handler lives inside it) and
  // re-export its `handler`; buildCodeArchive also ships the ESM resolve-hook so
  // the handler's bare @aws-sdk/* specifiers resolve from the managed runtime.
  let packageDirs = Dict.fromArray([
    ("@reventlessdev/reventless-aws", Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-aws")),
  ])
  let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
    ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Api/Platform_UIFragments_Lambda_Ops.res.mjs",
    ~packageDirs,
    ~bundleRuntimeExtensions=false,
  )

  let layers =
    Lambda.reventlessLayerArn
    ->Option.map(arn => [arn->Pulumi.Input.make])
    ->Option.getOr([])
    ->Pulumi.Input.make

  // Created before the function that writes to it — see
  // `Util_LambdaLogging.makeManagedLogGroup` for why the ordering matters.
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
      memorySize: 512->Pulumi.Input.make,
      timeout: 30->Pulumi.Input.make,
      layers,
      tags: AWS.Tags.make(~name=name ++ "Lambda", ~kind=ReventlessCore.ComponentType.Platform, ~role=Runtime, ~scope=Platform),
      environment: (
        {
          Lambda.Function.variables: Dict.fromArray([
            ("Environment", Pulumi.Pulumi.getStackName()->Pulumi.Input.make),
            ("UI_FRAGMENT_RM_TABLE", uiFragmentRegistryTableName->Pulumi.Output.asInput),
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
      open PolicyDocument
      let _attach = IAM.RolePolicy.make(
        ~name=name ++ "DataSource",
        ~args={
          IAM.RolePolicy.policy: PolicyDocument.make(
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

  // Create the resolver only after the admin schema push is ACTIVE — otherwise
  // CreateResolver races StartSchemaCreation the first time this field ships.
  let _resolver =
    schemaReady->Pulumi.Output.apply(() =>
      AppSync_Resolver_Native.makeUnitJsResolver(
        ~name=name ++ "Resolver",
        ~api,
        ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
        ~type_="Query"->Pulumi.Input.make,
        ~field="Platform_UIFragments"->Pulumi.Input.make,
        ~code=resolverCode,
        ~opts,
      )
    )
}
