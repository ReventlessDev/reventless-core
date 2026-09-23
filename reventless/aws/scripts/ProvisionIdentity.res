/***
Provision an identity provider that no Pulumi stack owns, and the active-role
store that belongs to it.

This is the BYO half of `Platform_Stack.resolveCognitoUserPool`. A stack given
`platform:identityProviderId` creates neither the pool nor the store — it looks
both up, and fails if either is missing. Something has to make them, once,
outside every stack. That is this.

🚨 **It does not attach a pre-token-generation trigger, and must not.** The pool's
one trigger slot is the deploy's business: a script that filled it would be the
hand-run `UpdateUserPool` this whole area refuses, leaving the deployment's
behaviour depending on an act no source describes.

The store's name and key schema come from [Auth_ActiveRoleStore_Schema] rather
than from constants here. A second copy of either would be one edit away from
creating a table the deploy does not look for — which surfaces as "table not
found" long after whoever ran this has moved on.

Reached as the `provision-identity` bin, from any package depending on
`@reventlessdev/reventless-aws` — an app's `platform-aws`, typically:

```
pnpm exec provision-identity --name MyIdentity
pnpm exec provision-identity --provider-id eu-west-1_AbCdEfGhI
```

Re-running is safe: existing resources are adopted and reported, never recreated.
The first thing anyone does with a provisioning script is run it twice.
*/

open AwsSdk

module Schema = Auth_ActiveRoleStore_Schema

// ── Arguments ────────────────────────────────────────────────────────────────

type args = {
  poolName: string,
  providerId: option<string>,
  loginIdentifier: Auth_LoginIdentifier.t,
  signUpMode: Auth_SignUpMode.t,
  help: bool,
}

let defaultPoolName = "ReventlessIdentity"

/** Parsed rather than positional, and unknown flags are an error: a typo'd
  `--provider-id` that parsed as "absent" would create a *second* pool beside the
  one the operator meant to extend. */
let parseArgs = (argv: array<string>): result<args, string> =>
  Reventless.CliArgs.parse(
    ~strings=["name", "provider-id", "login-identifier", "sign-up-mode"],
    argv,
  )
  ->Result.flatMap(Reventless.CliArgs.noPositionals)
  ->Result.flatMap(a => {
    let given = name => a->Reventless.CliArgs.string(name)
    let loginIdentifier = switch given("login-identifier") {
    | None => Ok(Auth_LoginIdentifier.default)
    | Some(_) as v => Auth_LoginIdentifier.parse(v)
    }
    let signUpMode = switch given("sign-up-mode") {
    | None => Ok(Auth_SignUpMode.default)
    | Some(_) as v => Auth_SignUpMode.parse(v)
    }
    switch (loginIdentifier, signUpMode) {
    | (Error(_) as e, _) | (_, Error(_) as e) => e
    | (Ok(loginIdentifier), Ok(signUpMode)) =>
      Ok({
        poolName: given("name")->Option.getOr(defaultPoolName),
        providerId: given("provider-id"),
        loginIdentifier,
        signUpMode,
        help: a->Reventless.CliArgs.help,
      })
    }
  })

let _loginIdentifiers =
  Auth_LoginIdentifier.all->Array.map(Auth_LoginIdentifier.toString)->Array.join(" | ")

let _defaultLoginIdentifier = Auth_LoginIdentifier.toString(Auth_LoginIdentifier.default)

let _signUpModes = Auth_SignUpMode.all->Array.map(Auth_SignUpMode.toString)->Array.join(" | ")

let _defaultSignUpMode = Auth_SignUpMode.toString(Auth_SignUpMode.default)

let usage = `
Usage: provision-identity [--name <name>] [--provider-id <id>] [--login-identifier <a>] [--sign-up-mode <m>]

Provision a Reventless identity provider and its active-role store.

  --name <name>          Pool name to create or adopt (default: ${defaultPoolName})
  --provider-id <id>     Use this existing pool instead of creating one; only the
                         store is provisioned
  --login-identifier <a> Sign-in attribute for a pool this creates: ${_loginIdentifiers}
                         (default: ${_defaultLoginIdentifier}). Fixed at creation —
                         no later change is possible without replacing the pool
                         and losing every account in it.
  --sign-up-mode <m>     Whether a stranger may register themselves: ${_signUpModes}
                         (default: ${_defaultSignUpMode}). Correctable later, but on a
                         pool shared between stacks it applies to all of them.

Creates nothing that a platform stack owns, and never attaches a trigger.
Region and credentials come from the environment, as for any AWS SDK call.
`

// ── The pool ─────────────────────────────────────────────────────────────────

/** SPA-friendly defaults, matching what auto mode declares: a 12-character
  password policy, no MFA, admin-only user creation. An operator wanting
  something else edits the pool afterwards rather than having this script grow a
  flag per Cognito setting.

  Two settings are exceptions and have flags, for two different reasons. The
  sign-in attribute, because it is the one setting no later edit can reach —
  Cognito offers no update for it. Sign-up mode, because a stack pointed at a
  supplied pool holds no handle to set it on, so "edit it afterwards" is the only
  other answer and it leaves the pool's two identity choices in two places. Both
  describe the pool itself rather than a policy detail. */
let poolSettings = (
  ~poolName: string,
  ~loginIdentifier: Auth_LoginIdentifier.t,
  ~signUpMode: Auth_SignUpMode.t,
): CognitoIdentityServiceProvider.CreateUserPoolCommand.input => {
  poolName,
  usernameAttributes: loginIdentifier->Auth_LoginIdentifier.usernameAttributes,
  mfaConfiguration: "OFF",
  adminCreateUserConfig: {
    allowAdminCreateUserOnly: signUpMode->Auth_SignUpMode.allowAdminCreateUserOnly,
  },
  policies: {
    passwordPolicy: {
      minimumLength: 12,
      requireLowercase: true,
      requireUppercase: true,
      requireNumbers: true,
    },
  },
}

/** The pool with this name, if exactly one has it.

  Cognito does not enforce unique pool names and offers no lookup by name, so
  adoption means paging the list. Without this a second run silently creates a
  second pool with the same name, and the operator then has two with no way to
  tell from the console which one their stacks are configured for.

  Two matches is an error rather than a choice — picking either would be a guess
  at which one holds the accounts. */
let findPoolByName = async (~poolName: string): result<option<string>, string> => {
  let nextToken = ref(None)
  let more = ref(true)
  let found = []
  while more.contents {
    let page = await CognitoIdentityServiceProvider.ListUserPoolsCommand.make({
      maxResults: 60,
      nextToken: ?nextToken.contents,
    })->CognitoIdentityServiceProvider.ListUserPoolsCommand.send
    page.userPools
    ->Option.getOr([])
    ->Array.forEach(p =>
      switch (p.name, p.id) {
      | (Some(name), Some(id)) if name == poolName => found->Array.push(id)
      | _ => ()
      }
    )
    switch page.nextToken {
    | Some(_) as t => nextToken := t
    | None => more := false
    }
  }
  switch found {
  | [] => Ok(None)
  | [only] => Ok(Some(only))
  | several =>
    Error(
      `${several
        ->Array.length
        ->Int.toString} user pools are named "${poolName}" (${several->Array.join(
          ", ",
        )}). Pass --provider-id to say which one to use; this script will not guess.`,
    )
  }
}

let resolvePool = async (~args: args): result<string, string> =>
  switch args.providerId {
  | Some(id) =>
    // Described rather than trusted: the store's name is derived from this id, so
    // a typo would produce a correctly-created table that nothing ever reads.
    let _ = await CognitoIdentityServiceProvider.DescribeUserPoolCommand.make({
      userPoolId: id,
    })->CognitoIdentityServiceProvider.DescribeUserPoolCommand.send
    Console.log(`pool     ${id} (given, unchanged)`)
    Ok(id)
  | None =>
    switch await findPoolByName(~poolName=args.poolName) {
    | Error(_) as e => e
    | Ok(Some(existing)) =>
      Console.log(`pool     ${existing} (adopted, named "${args.poolName}")`)
      Ok(existing)
    | Ok(None) =>
      let created = await CognitoIdentityServiceProvider.CreateUserPoolCommand.make(
        poolSettings(
          ~poolName=args.poolName,
          ~loginIdentifier=args.loginIdentifier,
          ~signUpMode=args.signUpMode,
        ),
      )->CognitoIdentityServiceProvider.CreateUserPoolCommand.send
      switch created.userPool->Option.flatMap(p => p.id) {
      | None => Error("CreateUserPool returned no pool id")
      | Some(id) =>
        Console.log(
          `pool     ${id} (created, named "${args.poolName}", sign-in on ${Auth_LoginIdentifier.toString(
              args.loginIdentifier,
            )}, sign-up ${Auth_SignUpMode.toString(args.signUpMode)})`,
        )
        Ok(id)
      }
    }
  }

// ── The store ────────────────────────────────────────────────────────────────

let keySchema: array<DynamoDb.DynamoDb.DescribeTableCommand.keySchemaElement> = [
  {attributeName: Schema.partitionKey, keyType: "HASH"},
  {attributeName: Schema.sortKey, keyType: "RANGE"},
]

/** The SDK's shape mapped onto the plain pairs [Schema.keySchemaRefusal] compares.
  The refusal itself lives with the schema it is about, since the schema is what
  it is a statement about — and it is shared with the deploy, which never sees
  this file. */
let asPairs = (elements: array<DynamoDb.DynamoDb.DescribeTableCommand.keySchemaElement>) =>
  elements->Array.map(k => (k.attributeName, k.keyType))

let describeTable = async (~tableName: string): option<
  DynamoDb.DynamoDb.DescribeTableCommand.tableDescription,
> =>
  try {
    let out = await DynamoDb.DynamoDb.DescribeTableCommand.make({
      tableName: tableName,
    })->DynamoDb.DynamoDb.DescribeTableCommand.send
    out.table
  } catch {
  | exn if Util_AwsError.isNotFound(exn) => None
  }

let provisionStore = async (~tableName: string): result<unit, string> =>
  switch await describeTable(~tableName) {
  | Some(described) =>
    switch Schema.keySchemaRefusal(
      ~tableName,
      ~actual=described.keySchema->Option.getOr([])->asPairs,
    ) {
    | Some(message) => Error(message)
    | None =>
      Console.log(`store    ${tableName} (adopted)`)
      Ok()
    }
  | None =>
    let _ = await DynamoDb.DynamoDb.CreateTableCommand.make({
      tableName,
      keySchema,
      attributeDefinitions: [
        {attributeName: Schema.partitionKey, attributeType: "S"},
        {attributeName: Schema.sortKey, attributeType: "S"},
      ],
      billingMode: "PAY_PER_REQUEST",
    })->DynamoDb.DynamoDb.CreateTableCommand.send

    let waited = await DynamoDb.DynamoDb.TableExistsWaiter.wait(~tableName)
    if !DynamoDb.DynamoDb.TableExistsWaiter.succeeded(waited) {
      Error(
        `table "${tableName}" was created but did not become ACTIVE (${waited.state}). Re-run this script — it adopts what is already there.`,
      )
    } else {
      // Matches what the framework's own tables carry, and it can only be turned
      // on once the table is ACTIVE — hence the wait above.
      let _ = await DynamoDb.DynamoDb.UpdateContinuousBackupsCommand.make({
        tableName,
        pointInTimeRecoverySpecification: {pointInTimeRecoveryEnabled: true},
      })->DynamoDb.DynamoDb.UpdateContinuousBackupsCommand.send
      Console.log(`store    ${tableName} (created)`)
      Ok()
    }
  }

// ── Main ─────────────────────────────────────────────────────────────────────

/** Printed rather than assumed: nothing here owns these resources, so nothing
  here can wire them up either. */
let nextSteps = (~providerId: string) =>
  `
Configure each platform stack that should use this provider:

  pulumi config set platform:identityProviderId ${providerId}

or set REVENTLESS_IDENTITY_PROVIDER_ID in CI. Every stack on this provider
derives the same store, so there is nothing else to configure.

The pre-token-generation trigger is attached by the deploy, not by this script.

Once a stack has deployed against this provider, make the first administrator:

  pnpm exec provision-admin --provider-id ${providerId} --email you@example.com

That is a separate bin because it provisions nothing a stack owns, and because it
is needed on a pool created here and on one a stack created for itself alike. See
[ProvisionAdmin].`

let run = async (args: args): result<unit, string> =>
  switch await resolvePool(~args) {
  | Error(_) as e => e
  | Ok(providerId) =>
    let tableName = Schema.derivedStoreName(~identityProviderId=providerId)
    switch await provisionStore(~tableName) {
    | Error(_) as e => e
    | Ok() =>
      Console.log(nextSteps(~providerId))
      Ok()
    }
  }

let cli: Reventless.CliArgs.cli<args> = {bin: "provision-identity", usage, parse: parseArgs}

/**
🚨 **Catches thrown exceptions, not only `Error` results.**

Without this an SDK failure escapes an async function nothing awaits, and Node
reports `UnhandledPromiseRejection ... "#<Object>"` — which names neither the call
that failed nor why. Every AWS call in this script can throw, so the top level has
to turn any of them into something an operator can read.
*/
let main = () =>
  Reventless.CliArgs.run(cli, async args =>
    switch await run(args) {
    | Ok() => ()
    | Error(message) =>
      Console.error(`provision-identity: ${message}`)
      NodeProcess.exit(1)
    | exception exn =>
      Console.error(`provision-identity: ${Util_AwsError.describe(exn)}`)
      NodeProcess.exit(1)
    }
  )

// 🚨 **No top-level call.** `../run-provision-identity.mjs` invokes [main]; this
// module only defines it. A module that ran itself on import could not be
// imported by a test — which is exactly how a guard that could never match
// shipped in this file once already.
