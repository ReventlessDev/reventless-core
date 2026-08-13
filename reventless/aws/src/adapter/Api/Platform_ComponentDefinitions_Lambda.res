// AWS resolver for the `Platform_ComponentDefinitions` admin GraphQL query.
//
// Backed by a Lambda DataSource that scans the Plugin read model and emits
// one entry per Connected plugin whose persisted state carries a `structure`
// field. The persisted structure is sury-encoded with the exact same shape
// the in-memory adapter's `Platform_ComponentDefinitionsApi.encodePluginStructureEntry`
// produces (literal-string `commandLevel`, `null`-encoded options), so the
// handler wraps each persisted structure with `pluginId` without decoding.
// One caveat: the persisted structure is PRE-filter — it still carries Internal
// ReadModels / StateViewSlices for developer tooling. The handler re-applies the
// `isPublicQueryable` filter (mirroring `encodePluginStructureEntry`) so Internal
// components stay out of the deployed AutoUI, matching the in-memory adapter.

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

// `Platform_PluginStructures` — the same scan, unfiltered. The `complete` flag is
// the whole difference; see the handler's `toEntryWith`.
let completeResolverCode = `
import { util } from '@aws-appsync/utils';
export function request(ctx) {
  return { operation: 'Invoke', payload: { complete: true } };
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
`->Pulumi.Input.make

/**
 What the platform needs back to finish wiring the bake.

 The manifest is written into the host-UI bucket, and that bucket is created in a
 later half of the same deploy — so the grant cannot be attached here. Handing the
 role back is what lets the caller attach it at the point both facts are known,
 rather than widening this function's write scope to "some bucket, later".

 `functionName` is exported so the post-deploy step has something to invoke
 without guessing at a generated name.
 */
type t = {
  roleId: Pulumi.Output.t<string>,
  functionName: Pulumi.Output.t<string>,
}

let make = (
  ~api: Pulumi.Output.t<AppSync.GraphQLApi.t>,
  ~pluginReadModelTableName: Pulumi.Output.t<string>,
  ~offloadBucketName: Pulumi.Output.t<string>,
  // Resolves once the admin schema push is ACTIVE (Platform_Admin.adminSchemaPushed).
  // Only the `Platform_PluginStructures` resolver is gated on it: that field is new,
  // so CreateResolver would otherwise race StartSchemaCreation on the deploy that
  // first ships it. `Platform_ComponentDefinitions` predates the gate and is left
  // ungated so this change adds no dependency edge to an already-deployed resource.
  ~schemaReady: Pulumi.Output.t<unit>,
  // The deployment's include-list, when it declares one. Carried into the
  // function's environment so the bake curates what the platform program
  // declared and not what its caller asked for — the invocation supplies only
  // where to write.
  ~bakedManifest: option<ReventlessInfra.Platform.bakedManifest>=?,
  ~opts: Pulumi.ComponentResource.options,
): t => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions
  let name = "PlatformUIDefinitions"

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
    (pluginReadModelTableName, offloadBucketName)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((tableName, offloadBucket)) => {
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
                sid: "AllowScanPluginRm",
                effect: Allow,
                actions: Actions(["dynamodb:Scan"]),
                resources: Resource("arn:aws:dynamodb:*:*:table/" ++ tableName),
              },
              // Offloaded `structure` payloads live in the platform's
              // content-addressed offload bucket; the handler GETs them by their
              // `sha256/<hash>` key and substitutes before filtering.
              {
                sid: "AllowOffloadGet",
                effect: Allow,
                actions: Actions(["s3:GetObject"]),
                resources: Resource("arn:aws:s3:::" ++ offloadBucket ++ "/*"),
              },
              // Read-only on the bucket itself, purely so a key that is not there
              // says so: S3 answers GET for a missing key with AccessDenied unless
              // the caller may list the bucket, which reports a ref the handler
              // cannot resolve as an IAM problem it does not have.
              {
                sid: "AllowOffloadList",
                effect: Allow,
                actions: Actions(["s3:ListBucket"]),
                resources: Resource("arn:aws:s3:::" ++ offloadBucket),
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

  // The include-list as the handler reads it. Encoded here rather than passed
  // as a record so the deploy input and the runtime input are the same shape —
  // `views`/`commands` absent means "every public component", which a record
  // with explicit nulls would not say.
  let bakeSelectionsJson = switch bakedManifest {
  | None => ""
  | Some(bake) =>
    bake.components
    ->Array.map(sel => {
      let entry = Dict.fromArray([("plugin", JSON.Encode.string(sel.plugin))])
      let strings = (key, value) =>
        value->Option.forEach(names =>
          entry->Dict.set(key, names->Array.map(JSON.Encode.string)->JSON.Encode.array)
        )
      strings("views", sel.views)
      strings("commands", sel.commands)
      entry->JSON.Encode.object
    })
    ->JSON.Encode.array
    ->JSON.stringify
  }

  let adminEntryJson =
    ReventlessCore.Platform_ComponentDefinitionsApi.encodePluginStructureEntry(
      ~pluginId=ReventlessCore.Platform_Admin_Structure.pluginId,
      ReventlessCore.Platform_Admin_Structure.structure,
    )->JSON.stringify

  // Bundle reventless-aws (the compiled `_Ops` handler lives inside it) and
  // re-export its `handler`; buildCodeArchive also ships the ESM resolve-hook so
  // the handler's bare @aws-sdk/* specifiers resolve from the managed runtime.
  // The admin entry rides the archive as `adminEntry.json` rather than an env var:
  // it alone encodes to ~3 KB, which together with the other variables exceeds the
  // 4096-byte UpdateFunctionConfiguration limit. Its content participates in
  // `sourceCodeHash`, so a change to the admin structure redeploys the code.
  let packageDirs = Dict.fromArray([
    ("@reventlessdev/reventless-aws", Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-aws")),
  ])
  let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
    ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Api/Platform_ComponentDefinitions_Lambda_Ops.res.mjs",
    ~packageDirs,
    ~extraStringAssets=Dict.fromArray([("adminEntry.json", adminEntryJson)]),
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
            ("PLUGIN_RM_TABLE", pluginReadModelTableName->Pulumi.Output.asInput),
            ("OFFLOAD_BUCKET", offloadBucketName->Pulumi.Output.asInput),
            // Absent declaration ⇒ empty string ⇒ a bake invocation fails saying
            // this platform declares none, rather than writing an empty shop.
            // An include-list is names only, so it stays far from the 4096-byte
            // total the admin entry already pushed out of this dict.
            ("BAKE_SELECTIONS", bakeSelectionsJson->Pulumi.Input.make),
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

  let _resolver = AppSync_Resolver_Native.makeUnitJsResolver(
    ~name=name ++ "Resolver",
    ~api,
    ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
    ~type_="Query"->Pulumi.Input.make,
    ~field="Platform_ComponentDefinitions"->Pulumi.Input.make,
    ~code=resolverCode,
    ~opts,
  )

  // Second field, same DataSource and same Lambda — the developer-tooling read of
  // the identical scan. Sharing the data source is what keeps the two answers from
  // drifting: there is one place that decides what a deployed plugin's structure is.
  // Created only after the schema carrying `Platform_PluginStructures` is ACTIVE.
  let _structuresResolver =
    schemaReady->Pulumi.Output.apply(() =>
      AppSync_Resolver_Native.makeUnitJsResolver(
        ~name=name ++ "StructuresResolver",
        ~api,
        ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
        ~type_="Query"->Pulumi.Input.make,
        ~field="Platform_PluginStructures"->Pulumi.Input.make,
        ~code=completeResolverCode,
        ~opts,
      )
    )

  {roleId: lambdaRole.id, functionName: lambda.name}
}
