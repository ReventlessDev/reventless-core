// Platform-level stack helpers — for resources that belong to the platform
// stack (not per-plugin) such as the Cognito UserPool used by every API.

type cognitoUserPool = {
  poolId: Pulumi.Output.t<string>,
  clientId: Pulumi.Output.t<string>,
  poolArn: Pulumi.Output.t<string>,
  managed: bool,
  /** Rows holding the role each caller chose to act as, read by the pool's
    pre-token-generation trigger. Carried on the resolved pool because the table
    has to be provisioned *before* the pool (the trigger reads it, and the pool
    is declared with the trigger's ARN), while the mutation that writes it is
    provisioned after the API — see [Auth_ActiveRoleStore.res]. */
  activeRoleTable: Auth_ActiveRoleStore.storeTable,
}

/**
 * Resolve the Cognito UserPool used by AppSync auth. Two modes:
 *
 * - **Auto**: no `platform:cognitoUserPoolId` config — create a fresh UserPool
 *   with SPA-friendly defaults (email username, 12-char password policy, no
 *   MFA, admin-only user creation). Caller is responsible for creating
 *   groups (`Admin`, `User`, …) and users via the AWS console / CLI.
 *
 * - **BYO**: pool ID provided — skip pool creation, look up the existing
 *   pool via `aws.cognito.getUserPool` for its ARN. Lookup precedence
 *   (highest → lowest):
 *     1. `REVENTLESS_COGNITO_USER_POOL_ID` env var (typically a CI secret).
 *     2. `Pulumi.local.yaml` sidecar key `cognitoUserPoolId` (gitignored;
 *        per-dev override).
 *     3. `platform:cognitoUserPoolId` in the checked-in `Pulumi.<stack>.yaml`.
 *
 * In both modes the framework owns the `UserPoolClient` (SPA settings would
 * not reliably exist on a pre-existing client; the client is a child resource
 * Pulumi can destroy without touching the parent pool).
 *
 * Always exports `cognitoUserPoolId`, `cognitoUserPoolClientId`,
 * `cognitoUserPoolArn`, `cognitoRegion`, and `cognitoUserPoolManaged` as
 * stack outputs so downstream stacks (and Stage D AppSync wiring) can read
 * them via `StackReference`.
 *
 * Also provisions the role-state table and the pre-token-generation trigger that
 * narrows `cognito:groups` to a caller's chosen role. They belong here rather
 * than beside the mutation that writes the table because the pool must be
 * declared carrying the trigger's ARN — see the ordering note below.
 */
let _resolveUncached = (): cognitoUserPool => {
  let cfg = Pulumi.Config.make(Some("platform"))
  let existingPoolId = switch Util_LocalConfig.get("cognitoUserPoolId") {
  | Some(_) as v => v
  | None => cfg->Pulumi.Config.get("cognitoUserPoolId")
  }

  // Provisioned ahead of the pool in both pool modes: the pre-token-generation
  // trigger reads these rows, and in auto mode the pool is declared carrying the
  // trigger's ARN — so table → trigger → pool is a forced order, not a choice.
  // See [docs/plans/active-role-narrows-the-token.md] §6.
  //
  // Unconditional, including for a unified-API platform that mounts no
  // `Platform_SetActiveRole` and so can never write a row.
  //
  // This was briefly gated on whether a write door would exist, to save a
  // DynamoDB read per sign-in in that mode. The gate was a parameter on this
  // function — and because the result is process-cached, it made the feature's
  // existence depend on *which caller resolved the pool first*. `Auth_Cognito.make`
  // reaches this through an adapter record and gets there before the platform
  // does, so the whole feature silently vanished from the deploy: no error, no
  // resource, nothing to notice. A local `pulumi preview` was the only thing that
  // caught it.
  //
  // Saving one GetItem in a legacy mode is not worth a switch whose failure mode
  // is a feature that quietly is not there. If the cost ever matters, the fix is
  // a design that does not hinge on call order — not this parameter again.
  let activeRoleTable = Auth_ActiveRoleStore.makeTable(~opts={})
  let activeRoleTrigger = Auth_ActiveRoleTrigger.make(
    ~activeRoleTableName=activeRoleTable.name->Pulumi.Output.asInput,
    ~activeRoleTableArn=activeRoleTable.arn->Pulumi.Output.asInput,
    ~opts={},
  )

  let result = switch existingPoolId {
  | Some(poolId) =>
    let tokenUnits: PulumiAws.Cognito.UserPoolClient.tokenValidityUnits = {
      accessToken: Pulumi.Input.make("minutes"),
      idToken: Pulumi.Input.make("minutes"),
      refreshToken: Pulumi.Input.make("days"),
    }
    let client = PulumiAws.Cognito.UserPoolClient.make(
      ~name="HostUiClient",
      ~args={
        userPoolId: Pulumi.Input.make(poolId),
        generateSecret: Pulumi.Input.make(false),
        explicitAuthFlows: Pulumi.Input.make([
          Pulumi.Input.make("ALLOW_USER_PASSWORD_AUTH"),
          Pulumi.Input.make("ALLOW_REFRESH_TOKEN_AUTH"),
        ]),
        preventUserExistenceErrors: Pulumi.Input.make("ENABLED"),
        idTokenValidity: Pulumi.Input.make(60),
        accessTokenValidity: Pulumi.Input.make(60),
        refreshTokenValidity: Pulumi.Input.make(30),
        tokenValidityUnits: Pulumi.Input.make(tokenUnits),
      },
    )

    let lookup = PulumiAws.Cognito.UserPool.getUserPoolOutput(~args={userPoolId: poolId})

    // BYO: we hold no handle to set `lambdaConfig` on, and Cognito offers no
    // separate attachment resource — so the trigger is attached by a declared
    // resource that describes the pool, merges into what it finds, and sends the
    // result back whole. Never a hand-run command: that would leave the
    // deployment's behaviour depending on an act no source describes.
    let _attachment = Auth_ActiveRolePoolAttachment.make(
      ~props={
        userPoolId: Pulumi.Input.make(poolId),
        preTokenGenerationArn: activeRoleTrigger.functionArn->Pulumi.Output.asInput,
      },
      ~opts={},
    )

    {
      poolId: Pulumi.Output.make(poolId),
      clientId: client.id,
      poolArn: lookup->Pulumi.Output.apply(r => r.arn),
      managed: false,
      activeRoleTable,
    }

  | None =>
    let adminConfig: PulumiAws.Cognito.UserPool.adminCreateUserConfig = {
      allowAdminCreateUserOnly: Pulumi.Input.make(true),
    }
    let pwdPolicy: PulumiAws.Cognito.UserPool.passwordPolicy = {
      minimumLength: Pulumi.Input.make(12),
      requireLowercase: Pulumi.Input.make(true),
      requireUppercase: Pulumi.Input.make(true),
      requireNumbers: Pulumi.Input.make(true),
    }
    // Auto: the pool is ours, so the trigger is an ordinary declared property and
    // no out-of-band `UpdateUserPool` is involved. Declaring it here rather than
    // attaching it afterwards also keeps Pulumi's own state the authority — an
    // attachment made behind the resource's back would read as drift on the next
    // refresh and be reverted.
    let pool = PulumiAws.Cognito.UserPool.make(
      ~name="HostUiPool",
      ~args={
        adminCreateUserConfig: Pulumi.Input.make(adminConfig),
        usernameAttributes: Pulumi.Input.make([Pulumi.Input.make("email")]),
        passwordPolicy: Pulumi.Input.make(pwdPolicy),
        mfaConfiguration: Pulumi.Input.make("OFF"),
        lambdaConfig: Pulumi.Input.make({
          PulumiAws.Cognito.UserPool.preTokenGeneration: activeRoleTrigger.functionArn->Pulumi.Output.asInput,
        }),
        tags: AWS.Tags.make(
          ~name="HostUiPool",
          ~kind=ReventlessCore.ComponentType.Platform,
          ~role=Auth,
          ~scope=Platform,
        ),
      },
    )

    let tokenUnits2: PulumiAws.Cognito.UserPoolClient.tokenValidityUnits = {
      accessToken: Pulumi.Input.make("minutes"),
      idToken: Pulumi.Input.make("minutes"),
      refreshToken: Pulumi.Input.make("days"),
    }
    let client = PulumiAws.Cognito.UserPoolClient.make(
      ~name="HostUiClient",
      ~args={
        userPoolId: pool.id->Pulumi.Output.asInput,
        generateSecret: Pulumi.Input.make(false),
        explicitAuthFlows: Pulumi.Input.make([
          Pulumi.Input.make("ALLOW_USER_PASSWORD_AUTH"),
          Pulumi.Input.make("ALLOW_REFRESH_TOKEN_AUTH"),
        ]),
        preventUserExistenceErrors: Pulumi.Input.make("ENABLED"),
        idTokenValidity: Pulumi.Input.make(60),
        accessTokenValidity: Pulumi.Input.make(60),
        refreshTokenValidity: Pulumi.Input.make(30),
        tokenValidityUnits: Pulumi.Input.make(tokenUnits2),
      },
    )

    {
      poolId: pool.id,
      clientId: client.id,
      poolArn: pool.arn,
      managed: true,
      activeRoleTable,
    }
  }

  // After the branch, because the permission is scoped to the pool's ARN and the
  // pool is what the branch produces.
  Auth_ActiveRoleTrigger.grantInvoke(
    ~trigger=activeRoleTrigger,
    ~cognitoUserPoolArn=result.poolArn->Pulumi.Output.asInput,
    ~opts={},
  )

  let regionStr =
    Pulumi.Config.make(Some("aws"))->Pulumi.Config.get("region")->Option.getOr("unknown")

  Pulumi.Pulumi.export("cognitoUserPoolId", result.poolId)
  Pulumi.Pulumi.export("cognitoUserPoolClientId", result.clientId)
  Pulumi.Pulumi.export("cognitoUserPoolArn", result.poolArn)
  Pulumi.Pulumi.export("cognitoRegion", Pulumi.Output.make(regionStr))
  Pulumi.Pulumi.export(
    "cognitoUserPoolManaged",
    Pulumi.Output.make(result.managed ? "true" : "false"),
  )

  result
}

// Process-level cache so multiple callers (Main.res + Auth_Cognito.make from
// inside Platform.MakeWithConfig) converge on the same pool/client and the
// stack-export calls happen exactly once per Pulumi run.
let _cached: ref<option<cognitoUserPool>> = ref(None)

/**
 🚨 **Takes no arguments, and must not grow any.** Everything here is provisioned
 on the *first* call and every later caller gets that same result — so a
 parameter would not configure the pool, it would configure whichever caller
 happened to arrive first. `Auth_Cognito.make` reaches this through an adapter
 record and gets here before the platform's own call does, which is not obvious
 from any call site. Anything that needs to vary belongs in [_resolveUncached],
 read from config or environment where every caller sees the same answer.
 */
let resolveCognitoUserPool = (): cognitoUserPool =>
  switch _cached.contents {
  | Some(p) => p
  | None =>
    let p = _resolveUncached()
    _cached := Some(p)
    p
  }
