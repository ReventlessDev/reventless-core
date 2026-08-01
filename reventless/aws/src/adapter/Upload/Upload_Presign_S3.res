// Direct-to-S3 upload service, mounted on the platform GraphQL API.
//
// Deploy-time only: `make` provisions one compiled-EntryPoint Lambda (a plain
// `Lambda.Function` whose code archive re-exports `handler` from the compiled,
// type-checked runtime module `Upload_Presign_S3_Ops` and ships the shared ESM
// resolve-hook loader), an IAM execution role scoped to CloudWatch Logs +
// `s3:PutObject`/`s3:DeleteObject`/`s3:GetObject` on the declared stores' prefixes,
// an AppSync Lambda data source, and two resolvers — `Mutation.Upload_Presign` and
// `Mutation.Upload_Release` — on the platform API.
//
// There is no Function URL and no anonymous surface: authentication is the platform
// API's Cognito authorizer, and the verified caller identity reaches the handler in
// the resolver payload (see the JS resolver code below). This is route B of
// [docs/plans/upload-release-path.md]; the anonymous Function URL and the unverified
// `decodeJwtSub` the mint side used to carry are gone.
//
// Why an EntryPoint and not a Pulumi `CallbackFunction`: the handler needs the AWS
// SDK v3 S3 presigner. A serialized closure bakes the deploy machine's
// version-specific SDK internals into the archive but then resolves `@smithy/*` and
// `@aws-sdk/*` transitives from independently-versioned layer/runtime sources that
// disagree at cold start. Shipping the compiled `_Ops` module with bare `@aws-sdk/*`
// imports, resolved through the resolve-hook, loads one internally consistent SDK.
// The runtime logic lives in [Upload_Presign_S3_Ops.res].

open PulumiAws

type serviceOutputs = {resources: array<Pulumi.Output.t<string>>}

// A store the service can presign into and release from. `qualified` is the
// `{plugin}.{store}` name the caller passes as the mutation's `store` argument;
// `bucketName` is the physical bucket; `servedPrefix` is the prefix keys are rooted
// at (and therefore the prefix IAM is scoped to).
type uploadStore = {
  qualified: string,
  bucketName: Pulumi.Input.t<string>,
  servedPrefix: string,
}

/**
The prefix presigned object keys are rooted at, and therefore the prefix the store
must be served under for the returned `/{key}` ref to resolve. Exported so the serve
side reads the same constant the mint side writes.
*/
let defaultServedPrefix = "uploads"

// JS resolver code (APPSYNC_JS runtime): pass the caller's arguments and the
// authorizer-verified identity to the Lambda, tagging the operation so one Lambda
// serves both mutations. CORS and auth belong to the API, not to this code.
let invokeCode = (operation: string): Pulumi.Input.t<string> =>
  `import { util } from '@aws-appsync/utils';
export function request(ctx) {
  const id = ctx.identity;
  return {
    operation: 'Invoke',
    payload: {
      operation: '${operation}',
      arguments: ctx.args,
      identity: id != null && id.sub != null
        ? { sub: id.sub, username: id.username, claims: id.claims }
        : null
    }
  };
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
`->Pulumi.Input.make

let make = (
  ~api: Pulumi.Output.t<AppSync.GraphQLApi.t>,
  ~stores: array<uploadStore>,
  ~releaseWindowSeconds: int=900,
  ~name: string="UploadService",
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

  // Resolve every store's physical bucket name once; both the env map the handler
  // reads and the IAM the presign/release grant needs are built from it.
  let resolvedStores =
    stores
    ->Array.map(s =>
      s.bucketName
      ->Pulumi.Output.fromInput
      ->Pulumi.Output.apply(b => (s.qualified, b, s.servedPrefix))
    )
    ->Pulumi.Output.all

  // CloudWatch Logs plus least-privilege S3 on each declared store's own keys.
  //
  // Scoped to `{bucket}/{servedPrefix}/*` per store, never the whole bucket:
  // `PutObject` presigns the upload, `DeleteObject` performs the release, and
  // `GetObject` backs the `HeadObject` the age check reads. One Lambda covers every
  // declared store (route B1) — but its reach is still the union of those prefixes,
  // not a wildcard, so it cannot touch a key outside a declared store.
  let _policy =
    resolvedStores->Pulumi.Output.apply(list => {
      let arns = list->Array.map(((_, bucket, prefix)) => `arn:aws:s3:::${bucket}/${prefix}/*`)
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
                sid: "AllowUploadObjectAccess",
                effect: Allow,
                actions: Actions(["s3:PutObject", "s3:DeleteObject", "s3:GetObject"]),
                resources: Resources(arns),
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

  // `UPLOAD_STORES` — the qualified-name → {bucket, prefix} map the handler resolves
  // the caller's `store` argument against.
  let uploadStoresJson =
    resolvedStores->Pulumi.Output.apply(list =>
      list
      ->Array.map(((qualified, bucket, prefix)) => (
        qualified,
        Dict.fromArray([
          ("bucket", JSON.Encode.string(bucket)),
          ("prefix", JSON.Encode.string(prefix)),
        ])->JSON.Encode.object,
      ))
      ->Dict.fromArray
      ->JSON.Encode.object
      ->JSON.stringify
    )

  // Bundle reventless-aws (the compiled `_Ops` handler lives inside it) and
  // re-export its `handler`; buildCodeArchive also ships the ESM resolve-hook.
  let packageDirs = Dict.fromArray([
    (
      "@reventlessdev/reventless-aws",
      Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-aws"),
    ),
  ])
  let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
    ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Upload/Upload_Presign_S3_Ops.res.mjs",
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
            ("UPLOAD_STORES", uploadStoresJson->Pulumi.Output.asInput),
            ("RELEASE_WINDOW_SECONDS", releaseWindowSeconds->Int.toString->Pulumi.Input.make),
            ("NODE_OPTIONS", Util_Bundle.esmLoaderNodeOptions->Pulumi.Input.make),
            ("ESM_FALLBACK_DIRS", Util_Bundle.esmFallbackDirs->Pulumi.Input.make),
          ]),
        }: Lambda.Function.functionEnvironment
      )->Pulumi.Input.make,
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

  let _presignResolver = AppSync_Resolver_Native.makeUnitJsResolver(
    ~name=name ++ "Presign",
    ~api,
    ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
    ~type_="Mutation"->Pulumi.Input.make,
    ~field="Upload_Presign"->Pulumi.Input.make,
    ~code=invokeCode("presign"),
    ~opts,
  )

  let _releaseResolver = AppSync_Resolver_Native.makeUnitJsResolver(
    ~name=name ++ "Release",
    ~api,
    ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
    ~type_="Mutation"->Pulumi.Input.make,
    ~field="Upload_Release"->Pulumi.Input.make,
    ~code=invokeCode("release"),
    ~opts,
  )

  {resources: [lambda.arn]}
}
