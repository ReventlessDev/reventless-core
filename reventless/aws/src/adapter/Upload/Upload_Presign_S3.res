// Direct-to-S3 upload presign service behind a public Lambda Function URL.
//
// Deploy-time only: `make` provisions a compiled-EntryPoint Lambda (a plain
// `Lambda.Function` whose code archive re-exports `handler` from the compiled,
// type-checked runtime module `Upload_Presign_S3_Ops` and ships the shared ESM
// resolve-hook loader), an IAM execution role scoped to CloudWatch Logs +
// `s3:PutObject` on the target bucket, and a Function URL (no auth) so a browser
// can request a presigned PUT.
//
// Why an EntryPoint and not a Pulumi `CallbackFunction`: the handler needs the
// AWS SDK v3 S3 presigner. A serialized closure bakes the deploy machine's
// version-specific SDK internals into the archive but then resolves `@smithy/*`
// and `@aws-sdk/*` transitives from independently-versioned layer/runtime sources
// that disagree at cold start (an inlined `client-s3` against a newer
// `@smithy/smithy-client` base whose constructor no longer sets `middlewareStack`
// → `new S3Client()` throws). Shipping the compiled `_Ops` module with bare
// `@aws-sdk/*` imports, resolved through the resolve-hook (`@aws-sdk/*` from the
// runtime, `@smithy/*`/`@reventlessdev/*` from the layer), loads one internally
// consistent SDK instead. The runtime logic lives in [Upload_Presign_S3_Ops.res].

open PulumiAws

type serviceOutputs = {
  url: Pulumi.Output.t<string>,
  resources: array<Pulumi.Output.t<string>>,
}

/**
The prefix presigned object keys are rooted at, and therefore the prefix the
store must be served under for the returned `/{key}` ref to resolve.

Exported so the serve side reads the same constant the mint side writes. The two
have to agree exactly: a mismatch deploys green and 404s every object, because
nothing at deploy time compares a minted key against a cache behavior.
*/
let defaultServedPrefix = "uploads"

let make = (
  ~bucketName: Pulumi.Input.t<string>,
  ~corsOrigins: array<string>=["*"],
  // Prefix the presigned object keys are rooted at; must match the served
  // bucket's CloudFront `{prefix}/*` behavior so the returned `/{key}` ref
  // resolves.
  ~servedPrefix: string=defaultServedPrefix,
  // Resource-name stem. Defaults to the single-service name this adapter had
  // when a deployment could only have one store, so the existing service keeps
  // its identity; declared stores each pass their own, because there is one
  // service per store.
  //
  // One service per store rather than one service with wildcard write across
  // stores: a single wide-scoped presigner reintroduces exactly the blast radius
  // the per-store split exists to remove, and it does so invisibly — every
  // upload still works.
  ~name: string="UploadPresignService",
  ~opts=?,
): serviceOutputs => {
  let serviceName = name
  let opts =
    opts->Option.map(ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions)

  let lambdaRole = IAM.Role.makeWithDefaultPolicy(
    ~name=serviceName,
    ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
    ~tags=AWS.Tags.make(
      ~name=serviceName,
      ~kind=ReventlessCore.ComponentType.Platform,
      ~role=Identity,
      ~scope=Platform,
    ),
    ~opts?,
  )

  // CloudWatch Logs (so failures are observable) plus least-privilege
  // `s3:PutObject` on this store's own keys.
  //
  // Scoped to `{bucket}/{servedPrefix}/*`, not to the whole bucket. Because keys
  // are rooted at the store's prefix in *both* layouts, this one expression is
  // least-privilege in both: a dedicated bucket's service still cannot write
  // outside its prefix, and a shared bucket's services cannot write into each
  // other's stores. The layouts stay one model — even the policy does not fork.
  let _policy =
    bucketName
    ->Pulumi.Output.fromInput
    ->Pulumi.Output.apply(b => {
      let arn = `arn:aws:s3:::${b}/${servedPrefix}/*`
      let _ = IAM.RolePolicy.make(
        ~name=`${serviceName}Policy`,
        ~args={
          policy: PolicyDocument.make(
            ~id=`${serviceName}Policy`,
            ~statements=[
              {
                sid: "AllowLambdaLogging",
                effect: Allow,
                actions: Actions(["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]),
                resources: Resource("arn:aws:logs:*:*:*"),
              },
              {
                sid: "AllowUploadPut",
                effect: Allow,
                actions: Action("s3:PutObject"),
                resources: Resource(arn),
              },
            ],
          )
          ->PolicyDocument.toJsonString
          ->Pulumi.Input.make,
          role: lambdaRole.id->Pulumi.Output.asInput,
        },
        ~opts?,
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
    ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Upload/Upload_Presign_S3_Ops.res.mjs",
    ~packageDirs,
  )

  let layers =
    Lambda.reventlessLayerArn
    ->Option.map(arn => [arn->Pulumi.Input.make])
    ->Option.getOr([])
    ->Pulumi.Input.make

  let lambda = Lambda.Function.make(
    ~name=serviceName,
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
        ~name=serviceName,
        ~kind=ReventlessCore.ComponentType.Platform,
        ~role=Runtime,
        ~scope=Platform,
      ),
      environment: (
        {
          Lambda.Function.variables: Dict.fromArray([
            ("Environment", Pulumi.Pulumi.getStackName()->Pulumi.Input.make),
            ("UPLOAD_BUCKET", bucketName),
            ("SERVED_PREFIX", Pulumi.Input.make(servedPrefix)),
            ("NODE_OPTIONS", Util_Bundle.esmLoaderNodeOptions->Pulumi.Input.make),
            ("ESM_FALLBACK_DIRS", Util_Bundle.esmFallbackDirs->Pulumi.Input.make),
          ]),
        }: Lambda.Function.functionEnvironment
      )->Pulumi.Input.make,
    },
    ~opts?,
  )

  let functionUrl = FunctionUrl.make(
    ~name=`${serviceName}Url`,
    ~args={
      authorizationType: FunctionUrl.None,
      functionName: lambda.name->Pulumi.Output.asInput,
      cors: (
        {
          allowMethods: ["POST"]->Array.map(Pulumi.Input.make)->Pulumi.Input.make,
          allowOrigins: corsOrigins->Array.map(Pulumi.Input.make)->Pulumi.Input.make,
          allowHeaders: ["*"]->Array.map(Pulumi.Input.make)->Pulumi.Input.make,
        }: FunctionUrl.cors
      )->Pulumi.Input.make,
    },
    ~opts?,
  )

  {
    url: functionUrl.functionUrl,
    resources: [lambda.arn, functionUrl.functionArn],
  }
}
