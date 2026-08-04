// AWS Location Service geocoder, mounted on the platform GraphQL API.
//
// Deploy-time only: `make` provisions one compiled-EntryPoint Lambda (a plain
// `Lambda.Function` whose code archive re-exports `handler` from the compiled,
// type-checked runtime module `Geocoder_AwsLocation_Resolver_Ops` and ships the
// shared ESM resolve-hook loader), an IAM execution role scoped to CloudWatch Logs
// + `geo:SearchPlaceIndexForText` on the target place index, an AppSync Lambda data
// source, and one resolver — `Query.geocode` — on the platform API.
//
// There is no Function URL and no anonymous surface: authentication is the platform
// API's Cognito authorizer. This is the *client* door of the geocoding capability
// (D9 half 2), replacing the public Function URL the browser used to call. The
// unattended slice path reaches the same place index through the SDK directly
// (`Geocoder_AwsLocation_Backend`), so one capability, two doors — the same shape
// the object store already has with `Upload_Presign` and `Offload.resolve`.
//
// Why an EntryPoint and not a Pulumi `CallbackFunction`: same SDK-skew reason as the
// upload service — a serialized closure bakes the deploy machine's version-specific
// AWS SDK internals into the archive but then resolves `@smithy/*`/`@aws-sdk/*`
// transitives from independently-versioned layer/runtime sources that disagree at
// cold start. Shipping the compiled `_Ops` module with bare `@aws-sdk/*` imports,
// resolved through the resolve-hook, loads one internally consistent SDK. The
// runtime logic lives in [Geocoder_AwsLocation_Resolver_Ops.res].

open PulumiAws

type serviceOutputs = {resources: array<Pulumi.Output.t<string>>}

// JS resolver code (APPSYNC_JS runtime): forward the caller's arguments to the
// Lambda. CORS and auth belong to the API, not to this code. No identity is
// forwarded — geocoding is not scoped per caller (any authenticated user may
// resolve any address), unlike the upload service which namespaces objects by the
// verified `sub`.
let invokeCode: Pulumi.Input.t<string> =
  `import { util } from '@aws-appsync/utils';
export function request(ctx) {
  return { operation: 'Invoke', payload: { arguments: ctx.args } };
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
`->Pulumi.Input.make

let make = (
  ~api: Pulumi.Output.t<AppSync.GraphQLApi.t>,
  ~placeIndexName: Pulumi.Input.t<string>,
  ~name: string="GeocodeService",
  ~opts: Pulumi.ComponentResource.options,
): serviceOutputs => {
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

  // CloudWatch Logs (so failures are observable) plus least-privilege
  // `geo:SearchPlaceIndexForText` on the one place index — the same grant the
  // Function URL flavour carried, now on a resolver-invoked Lambda.
  let _policy =
    placeIndexName
    ->Pulumi.Output.fromInput
    ->Pulumi.Output.apply(idx => {
      let arn = `arn:aws:geo:*:*:place-index/${idx}`
      let _ = IAM.RolePolicy.make(
        ~name=name ++ "LambdaPolicy",
        ~args={
          policy: PolicyDocument.make(
            ~id=name ++ "LambdaPolicy",
            ~statements=[
              {
                sid: "AllowLambdaLogging",
                effect: Allow,
                actions: Actions(["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]),
                resources: Resource("arn:aws:logs:*:*:*"),
              },
              {
                sid: "AllowGeocode",
                effect: Allow,
                actions: Action("geo:SearchPlaceIndexForText"),
                resources: Resource(arn),
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
  // re-export its `handler`; buildCodeArchive also ships the ESM resolve-hook.
  let packageDirs = Dict.fromArray([
    (
      "@reventlessdev/reventless-aws",
      Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-aws"),
    ),
  ])
  let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
    ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Geocoder/Geocoder_AwsLocation_Resolver_Ops.res.mjs",
    ~packageDirs,
  )

  let layers =
    Lambda.reventlessLayerArn
    ->Option.map(arn => [arn->Pulumi.Input.make])
    ->Option.getOr([])
    ->Pulumi.Input.make

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
            ("PLACE_INDEX_NAME", placeIndexName),
            ("NODE_OPTIONS", Util_Bundle.esmLoaderNodeOptions->Pulumi.Input.make),
            ("ESM_FALLBACK_DIRS", Util_Bundle.esmFallbackDirs->Pulumi.Input.make),
            Util_LambdaLogging.logLevelEntry(),
          ]),
        }: Lambda.Function.functionEnvironment
      )->Pulumi.Input.make,
    },
    ~opts,
  )

  Util_LambdaLogging.makeManagedLogGroup(
    ~name=name ++ "Lambda",
    ~lambdaName=lambda.name,
    ~tags=AWS.Tags.make(
      ~name=name ++ "LambdaLogGroup",
      ~kind=ReventlessCore.ComponentType.Platform,
      ~role=Logs,
      ~scope=Platform,
    ),
    ~opts,
    (),
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

  let _geocodeResolver = AppSync_Resolver_Native.makeUnitJsResolver(
    ~name=name ++ "Geocode",
    ~api,
    ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
    ~type_="Query"->Pulumi.Input.make,
    ~field="geocode"->Pulumi.Input.make,
    ~code=invokeCode,
    ~opts,
  )

  {resources: [lambda.arn]}
}
