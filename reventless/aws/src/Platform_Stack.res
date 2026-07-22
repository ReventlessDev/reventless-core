// Platform-level stack helpers — for resources that belong to the platform
// stack (not per-plugin) such as the Cognito UserPool used by every API.

type cognitoUserPool = {
  poolId: Pulumi.Output.t<string>,
  clientId: Pulumi.Output.t<string>,
  poolArn: Pulumi.Output.t<string>,
  managed: bool,
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
 */
let _resolveUncached = (): cognitoUserPool => {
  let cfg = Pulumi.Config.make(Some("platform"))
  let existingPoolId = switch Util_LocalConfig.get("cognitoUserPoolId") {
  | Some(_) as v => v
  | None => cfg->Pulumi.Config.get("cognitoUserPoolId")
  }

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

    {
      poolId: Pulumi.Output.make(poolId),
      clientId: client.id,
      poolArn: lookup->Pulumi.Output.apply(r => r.arn),
      managed: false,
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
    let pool = PulumiAws.Cognito.UserPool.make(
      ~name="HostUiPool",
      ~args={
        adminCreateUserConfig: Pulumi.Input.make(adminConfig),
        usernameAttributes: Pulumi.Input.make([Pulumi.Input.make("email")]),
        passwordPolicy: Pulumi.Input.make(pwdPolicy),
        mfaConfiguration: Pulumi.Input.make("OFF"),
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
    }
  }

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

let resolveCognitoUserPool = (): cognitoUserPool =>
  switch _cached.contents {
  | Some(p) => p
  | None =>
    let p = _resolveUncached()
    _cached := Some(p)
    p
  }
