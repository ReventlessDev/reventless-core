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
 * - **Auto**: no `platform:identityProviderId` config — create a fresh UserPool
 *   with SPA-friendly defaults (email username, 12-char password policy, no
 *   MFA, admin-only user creation). Caller is responsible for creating
 *   groups (`Admin`, `User`, …) and users via the AWS console / CLI.
 *
 * - **BYO**: provider ID provided — skip pool creation, look up the existing
 *   pool via `aws.cognito.getUserPool` for its ARN. Lookup precedence
 *   (highest → lowest):
 *     1. `REVENTLESS_IDENTITY_PROVIDER_ID` env var (typically a CI secret).
 *     2. `Pulumi.local.yaml` sidecar key `identityProviderId` (gitignored;
 *        per-dev override).
 *     3. `platform:identityProviderId` in the checked-in `Pulumi.<stack>.yaml`.
 *
 *   The former `cognitoUserPoolId` spelling is still read at every level, and
 *   warns — see `_deprecatedPoolIdKey` for why dropping it is its own act.
 *
 * In both modes the framework owns the `UserPoolClient` (SPA settings would
 * not reliably exist on a pre-existing client; the client is a child resource
 * Pulumi can destroy without touching the parent pool).
 *
 * Always exports `cognitoUserPoolId`, `cognitoUserPoolClientId`,
 * `cognitoUserPoolArn`, `cognitoRegion`, `cognitoUserPoolManaged` and
 * `activeRoleStore` as stack outputs so downstream stacks (and Stage D AppSync
 * wiring) can read them via `StackReference`.
 *
 * Also provisions the role-state table and the pre-token-generation trigger that
 * narrows `cognito:groups` to a caller's chosen role. They belong here rather
 * than beside the mutation that writes the table because the pool must be
 * declared carrying the trigger's ARN — see the ordering note below.
 *
 * In BYO mode the store follows the provider rather than the stack: its name is
 * derived from the provider id, it is looked up rather than created, and it is
 * provisioned outside every stack alongside the pool. Either lookup finding
 * nothing fails the deploy — the provider and its store exist together or not
 * at all.
 */
let log = ReventlessCore.Logger.fromEnv()

/** The key that was `cognitoUserPoolId` before the concept was named for what it
  is rather than for the service implementing it.

  🚨 **Still read, and it must stay read until every caller has moved.** An absent
  provider id is not an error here — it is auto mode, and auto mode *creates a
  user pool*. So a caller left on the old key after this stopped reading it would
  not fail: it would deploy green, mint a fresh pool, and orphan every account in
  the old one. Dropping this fallback is a separate act, done once the callers are
  known to have moved, not a tidy-up. */
let _deprecatedPoolIdKey = "cognitoUserPoolId"

let _identityProviderId = (~cfg: Pulumi.Config.t): option<string> => {
  let read = key =>
    switch Util_LocalConfig.get(key) {
    | Some(_) as v => v
    | None => cfg->Pulumi.Config.get(key)
    }
  switch read("identityProviderId") {
  | Some(_) as v => v
  | None =>
    read(_deprecatedPoolIdKey)->Option.map(id => {
      log.warn(
        ~comp="Platform_Stack",
        `platform:${_deprecatedPoolIdKey} (REVENTLESS_COGNITO_USER_POOL_ID) is deprecated — rename it to platform:identityProviderId (REVENTLESS_IDENTITY_PROVIDER_ID). Still honoured, because dropping it silently would deploy in auto mode and create a NEW user pool.`,
      )
      id
    })
  }
}

let _resolveUncached = (): cognitoUserPool => {
  let cfg = Pulumi.Config.make(Some("platform"))
  let existingPoolId = _identityProviderId(~cfg)

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
  //
  // 🚨 **On a provider we do not own, the rows do not belong to this stack.** A
  // pool holds one pre-token-generation trigger, so two stacks sharing a pool with
  // a table each have the winning trigger reading rows the serving resolver never
  // wrote — every role switch succeeds and does nothing. So the store follows the
  // provider: named by derivation from the provider id, looked up rather than
  // created, and provisioned outside every stack alongside the pool itself. See
  // [Auth_ActiveRoleStore.chooseStore] and
  // [docs/plans/active-role-store-scoped-to-the-pool.md].
  let activeRoleTable = Auth_ActiveRoleStore.resolveTable(
    ~choice=Auth_ActiveRoleStore.chooseStore(~identityProviderId=existingPoolId),
    ~opts={},
  )
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
    // The code hash is an input so a new build of the trigger reaches this
    // resource: the function ARN is stable, so it alone would let a broken
    // version onto the pool unchecked after the first deploy.
    //
    // The store travels with it because the pool has one trigger slot: the
    // resource compares this against the store read by whatever already holds the
    // slot, and refuses rather than taking it from a trigger that disagrees.
    let _attachment = Auth_ActiveRolePoolAttachment.make(
      ~props={
        userPoolId: Pulumi.Input.make(poolId),
        preTokenGenerationArn: activeRoleTrigger.functionArn->Pulumi.Output.asInput,
        codeHash: Pulumi.Input.make(activeRoleTrigger.sourceCodeHash),
        activeRoleStore: activeRoleTable.name->Pulumi.Output.asInput,
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
  // Exported so a second stack meant to share this pool has a name to put in its
  // own `platform:activeRoleStore` — without it, pointing two stacks at one store
  // means reading a table name out of the console.
  Pulumi.Pulumi.export("activeRoleStore", result.activeRoleTable.name)

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
