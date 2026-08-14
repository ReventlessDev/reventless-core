// Deploy-time half of the Cognito pre-token-generation trigger — the Lambda that
// narrows `cognito:groups` to the role a caller chose. Runtime logic lives in
// [Auth_ActiveRoleTrigger_Ops.res]; see
// [docs/plans/active-role-narrows-the-token.md] §6.
//
// `make` provisions the function and its execution role (Logs + a read of the
// one role-state table). It does **not** attach itself to a user pool, and does
// not grant Cognito permission to invoke it: both need the pool, and in auto
// mode the pool needs this function's ARN first — the pool cannot be declared
// with a trigger that does not exist yet. So `make` runs before the pool, and
// [grantInvoke] runs after it.
//
// Attaching is a separate step again ([Auth_ActiveRolePoolAttachment.res] in BYO
// mode, `lambdaConfig` on the declared pool in auto mode), kept apart because it
// is the only part of this feature that can damage something that already
// exists.

open PulumiAws

type triggerOutputs = {
  functionArn: Pulumi.Output.t<string>,
  functionName: Pulumi.Output.t<string>,
  /** The archive's hash, exposed so whoever attaches this trigger to a pool can
      tell that the code changed. The function ARN does not move when the code
      does, so without this an attachment sees identical inputs across deploys
      and never re-checks a function it proved once. */
  sourceCodeHash: string,
}

let make = (
  ~activeRoleTableName: Pulumi.Input.t<string>,
  ~activeRoleTableArn: Pulumi.Input.t<string>,
  ~name: string="ActiveRoleTrigger",
  ~opts: Pulumi.ComponentResource.options,
): triggerOutputs => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let lambdaRole = IAM.Role.makeWithDefaultPolicy(
    ~name,
    ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
    ~tags=AWS.Tags.make(
      ~name,
      ~kind=ReventlessCore.ComponentType.Platform,
      ~role=Identity,
      ~scope=Platform,
    ),
    ~opts,
  )

  // Logs and a single-item read. Nothing else: the trigger needs no Cognito
  // permission at all, because the membership it checks against arrives in the
  // event as `request.groupConfiguration.groupsToOverride`. `GetItem` alone —
  // this function must never be able to write the preference it reads.
  let _policy =
    activeRoleTableArn
    ->Pulumi.Output.fromInput
    ->Pulumi.Output.apply(tableArn => {
      let _ = IAM.RolePolicy.make(
        ~name=name ++ "Policy",
        ~args={
          policy: PolicyDocument.make(
            ~id=name ++ "Policy",
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
                sid: "AllowReadingStoredRole",
                effect: Allow,
                actions: Action("dynamodb:GetItem"),
                resources: Resource(tableArn),
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
    ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Auth/Auth_ActiveRoleTrigger_Ops.res.mjs",
    ~packageDirs,
    ~bundleRuntimeExtensions=false,
  )

  let layers =
    Lambda.reventlessLayerArn
    ->Option.map(arn => [arn->Pulumi.Input.make])
    ->Option.getOr([])
    ->Pulumi.Input.make

  let logGroup = Util_LambdaLogging.makeManagedLogGroup(
    ~name,
    ~tags=AWS.Tags.make(
      ~name=name ++ "LogGroup",
      ~kind=ReventlessCore.ComponentType.Platform,
      ~role=Logs,
      ~scope=Platform,
    ),
    ~opts,
    (),
  )

  // This function sits in the critical path of every token the pool mints, so a
  // cold start is a login's latency and a timeout is a failed sign-in. One
  // `GetItem` needs neither much memory nor much time; 5s is well inside
  // Cognito's own 5s trigger budget, so the function fails before Cognito gives
  // up on it rather than after.
  let lambda = Lambda.Function.make(
    ~name,
    ~args={
      handler: "index.handler"->Pulumi.Input.make,
      runtime: "nodejs22.x"->Pulumi.Input.make,
      code: code->Pulumi.Input.make,
      sourceCodeHash: sourceCodeHash->Pulumi.Input.make,
      role: lambdaRole.arn->Pulumi.Output.asInput,
      memorySize: 256->Pulumi.Input.make,
      timeout: 5->Pulumi.Input.make,
      layers,
      tags: AWS.Tags.make(
        ~name,
        ~kind=ReventlessCore.ComponentType.Platform,
        ~role=Runtime,
        ~scope=Platform,
      ),
      environment: (
        {
          Lambda.Function.variables: Dict.fromArray([
            ("Environment", Pulumi.Pulumi.getStackName()->Pulumi.Input.make),
            ("ACTIVE_ROLE_TABLE", activeRoleTableName),
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

  {functionArn: lambda.arn, functionName: lambda.name, sourceCodeHash}
}

/** Let Cognito invoke the trigger — scoped to one pool, so a function attached
  to a pool nobody declared still cannot be invoked by it.

  Separate from [make] because the pool's ARN is not known until the pool exists,
  and in auto mode the pool is declared *with* the function's ARN. */
let grantInvoke = (
  ~trigger: triggerOutputs,
  ~cognitoUserPoolArn: Pulumi.Input.t<string>,
  ~name: string="ActiveRoleTrigger",
  ~opts: Pulumi.ComponentResource.options,
): unit => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions
  let _permission = trigger.functionName->Pulumi.Output.apply(functionName => {
    let _ = Lambda.Permission.make(
      ~name=name ++ "Invoke",
      ~args={
        action: "lambda:InvokeFunction",
        function: functionName->Pulumi.Input.make,
        principal: "cognito-idp.amazonaws.com",
        sourceArn: cognitoUserPoolArn,
      },
      ~opts,
    )
  })
}
