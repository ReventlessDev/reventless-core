// AWS Location Service geocoder behind a public Lambda Function URL.
//
// Deploy-time only: `make` provisions a compiled-EntryPoint Lambda (a plain
// `Lambda.Function` whose code archive re-exports `handler` from the compiled,
// type-checked runtime module `Geocoder_AwsLocation_Ops` and ships the shared
// ESM resolve-hook loader), an IAM execution role scoped to CloudWatch Logs +
// `geo:SearchPlaceIndexForText` on the target place index, and a Function URL
// (no auth) so a browser can geocode directly.
//
// Why an EntryPoint and not a Pulumi `CallbackFunction`: a serialized closure
// bakes the deploy machine's version-specific AWS SDK internals into the archive
// but then resolves `@smithy/*`/`@aws-sdk/*` transitives from independently-
// versioned layer/runtime sources that can disagree at cold start (the exact
// skew that crashed the upload presign service). Shipping the compiled `_Ops`
// module with bare `@aws-sdk/*` imports, resolved through the resolve-hook, loads
// one internally consistent SDK. The runtime logic lives in
// [Geocoder_AwsLocation_Ops.res].

open PulumiAws

type serviceOutputs = {
  url: Pulumi.Output.t<string>,
  resources: array<Pulumi.Output.t<string>>,
}

let make = (
  ~placeIndexName: Pulumi.Input.t<string>,
  ~corsOrigins: array<string>=["*"],
  ~opts=?,
): serviceOutputs => {
  let serviceName = "GeocoderService"
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
  // `geo:SearchPlaceIndexForText` on the one place index.
  let _policy =
    placeIndexName
    ->Pulumi.Output.fromInput
    ->Pulumi.Output.apply(idx => {
      let arn = `arn:aws:geo:*:*:place-index/${idx}`
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
    ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Geocoder/Geocoder_AwsLocation_Ops.res.mjs",
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
            ("PLACE_INDEX_NAME", placeIndexName),
            ("NODE_OPTIONS", Util_Bundle.esmLoaderNodeOptions->Pulumi.Input.make),
            ("ESM_FALLBACK_DIRS", Util_Bundle.esmFallbackDirs->Pulumi.Input.make),
            Util_LambdaLogging.logLevelEntry(),
          ]),
        }: Lambda.Function.functionEnvironment
      )->Pulumi.Input.make,
    },
    ~opts?,
  )

  Util_LambdaLogging.makeManagedLogGroup(
    ~name=serviceName,
    ~lambdaName=lambda.name,
    ~tags=AWS.Tags.make(
      ~name=serviceName ++ "LogGroup",
      ~kind=ReventlessCore.ComponentType.Platform,
      ~role=Logs,
      ~scope=Platform,
    ),
    ~opts?,
    (),
  )

  let functionUrl = FunctionUrl.make(
    ~name=`${serviceName}Url`,
    ~args={
      authorizationType: FunctionUrl.None,
      functionName: lambda.name->Pulumi.Output.asInput,
      cors: (
        {
          allowMethods: ["GET"]->Array.map(Pulumi.Input.make)->Pulumi.Input.make,
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
