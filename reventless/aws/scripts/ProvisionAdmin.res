/***
Make the first administrator of a deployment.

A stack creates a user pool, an app client and — in auto mode — the
administrator group. It creates no *accounts*, and it should not: a pool full of
people is not something a `pulumi destroy` should be able to empty, and Cognito
exports no password material, so a replaced account is a lost one. Something has
to make the first one, once, outside every stack. That is this.

Until it existed the answer was the AWS console, and nothing said so. A deploy
succeeded, the app loaded, sign-in failed, and no page in the repo covered what to
do next — the most expensive kind of first impression, met by whoever has the
least context: someone evaluating the framework on their first cloud deploy.

```
pnpm exec provision-admin --provider-id eu-west-1_AbCdEfGhI --email me@example.com
```

Works the same on a pool the stack owns and one it does not, which is why it is
its own bin rather than a flag on `provision-identity`. That script provisions the
*provider* — a pool and the active-role store derived from its id — and both are
BYO concerns; run against an auto-mode pool it would create a second store at a
derived name that no stack ever reads. The first administrator is needed in both
modes and is infrastructure in neither, so it is asked for separately.

🚨 **It provisions nothing a stack owns.** No pool, no store, no trigger. The
group is the one exception and only because it may be missing: on a supplied pool
no stack declares it — see [Platform_Stack] for why a pool-level fact is not a
borrowed pool's stack's to declare.

Re-running is safe, and the first thing anyone does with a provisioning script is
run it twice: an existing group and an existing user are both reported rather than
refused. The password is re-minted on every run, which is the one thing that does
change — see [passwordNote].
*/

open AwsSdk

module Cognito = CognitoIdentityServiceProvider

// ── Arguments ────────────────────────────────────────────────────────────────

type args = {
  providerId: option<string>,
  stack: option<string>,
  email: option<string>,
  help: bool,
}

/** Parsed rather than positional, and unknown flags are an error — the reason
  [ProvisionIdentity.parseArgs] gives, arriving somewhere worse: a typo'd
  `--email` that parsed as "absent" would be caught by the required-argument check
  below, but a typo'd `--provider-id` would fall through to the environment and
  create the administrator in a *different pool* than the operator named. */
let parseArgs = (argv: array<string>): result<args, string> => {
  let acc = ref(Ok({providerId: None, stack: None, email: None, help: false}))
  let i = ref(0)
  let count = argv->Array.length
  while i.contents < count {
    let flag = argv->Array.getUnsafe(i.contents)
    let value = argv->Array.get(i.contents + 1)
    switch (acc.contents, flag, value) {
    | (Error(_), _, _) => i := count
    | (Ok(a), "--provider-id", Some(v)) =>
      acc := Ok({...a, providerId: Some(v)})
      i := i.contents + 2
    | (Ok(a), "--stack", Some(v)) =>
      acc := Ok({...a, stack: Some(v)})
      i := i.contents + 2
    | (Ok(a), "--email", Some(v)) =>
      acc := Ok({...a, email: Some(v)})
      i := i.contents + 2
    | (Ok(a), "--help", _) | (Ok(a), "-h", _) =>
      acc := Ok({...a, help: true})
      i := i.contents + 1
    | (Ok(_), "--provider-id", None) | (Ok(_), "--email", None) | (Ok(_), "--stack", None) =>
      acc := Error(`${flag} needs a value`)
    | (Ok(_), unknown, _) => acc := Error(`unknown argument "${unknown}"`)
    }
  }
  acc.contents
}

let usage = `
Make the first administrator of a Reventless deployment.

  --provider-id <id>   The identity provider to create the account in. Usually
                       omitted: it falls back to ${ProvisionProvider.envKey},
                       then to the identityProviderId exported by the selected
                       Pulumi stack — which every deployment exports, whether it
                       created the pool or was handed one.
  --stack <name>       Read that output from this stack instead of the selected
                       one. The run always names the stack it used.
  --email <address>    The address they sign in with.

Creates the "${Reventless.AdminGroup.name}" group if it is missing, the account if
it is missing, a working password, and the membership between them. Provisions
nothing that a platform stack owns. Region and credentials come from the
environment, as for any AWS SDK call.
`

// ── The pool ─────────────────────────────────────────────────────────────────

/**
Refuse a pool this account could never sign in to.

The sign-in attribute is fixed at pool creation and no update can change it — see
[Auth_LoginIdentifier] — so an email address handed to a phone-only pool produces
a correctly-created account that simply cannot authenticate, and the symptom
arrives at a login screen far from the run that caused it. Described rather than
assumed for the same reason `provision-identity` describes a supplied pool.

No `UsernameAttributes` at all means the pool signs in on a plain username, which
takes an email-shaped one happily.
*/
let checkPoolAcceptsEmail = async (~providerId: string): result<unit, string> =>
  switch await ProvisionCognito.usernameAttributes(~providerId) {
  | Error(_) as e => e
  | Ok(attributes) =>
    if attributes->Array.length == 0 || attributes->Array.includes("email") {
      Console.log(`pool     ${providerId}`)
      Ok()
    } else {
      Error(
        `pool "${providerId}" signs in on ${attributes->Array.join(
            ", ",
          )}, not email, so an account created from --email could never authenticate. The sign-in attribute is fixed at pool creation and no update can change it.`,
      )
    }
  }

// ── The account ──────────────────────────────────────────────────────────────

let describe = (outcome: ProvisionCognito.outcome) =>
  switch outcome {
  | Created => "created"
  | AlreadyPresent => "already present"
  }

/** The group, where a stack has not already declared it. See
  [ProvisionCognito.ensureGroup] for why a supplied pool needs one made here. */
let ensureGroup = async (~providerId: string, ~group: string): unit => {
  let outcome = await ProvisionCognito.ensureGroup(
    ~providerId,
    ~group,
    ~description="Reventless administrators",
  )
  Console.log(`group    ${group} (${outcome->describe})`)
}

/**
The account, where it is not already there.

`email_verified` is stamped true because nothing here can complete a verification
round-trip, and an unverified address leaves the account able to sign in but
unable to recover a password — a bootstrap that works once and strands its owner.
*/
let ensureUser = async (~providerId: string, ~email: string): unit => {
  let attributes: array<Cognito.AdminCreateUserCommand.attributeType> = [
    {name: "email", value: email},
    {name: "email_verified", value: "true"},
  ]
  let outcome = await ProvisionCognito.ensureUser(~providerId, ~username=email, ~attributes)
  Console.log(`user     ${email} (${outcome->describe})`)
}

/** A password the account can actually be used with — see
  [ProvisionCognito.setPassword] for why it is permanent rather than temporary.

  Unconditional rather than skipped for an account that already exists, which is
  what makes a second run useful instead of merely harmless: the operator who runs
  this again is usually the one who has lost the password. */
let setPassword = async (~providerId: string, ~email: string, ~password: string): unit => {
  await ProvisionCognito.setPassword(~providerId, ~username=email, ~password)
  Console.log(`password (set, permanent)`)
}

let addToGroup = async (~providerId: string, ~email: string, ~group: string): unit => {
  await ProvisionCognito.addToGroup(~providerId, ~username=email, ~group)
  Console.log(`member   ${email} in ${group}`)
}

// ── Main ─────────────────────────────────────────────────────────────────────

/**
🚨 **Printed, and this is a deliberate trade rather than an oversight.**

Cognito keeps no recoverable copy, so a generated password exists in this output
or nowhere. Printing it is friendliest for the case this script is for — a
developer at a terminal on their first deploy — and the cost is that it lands in
scrollback, and in a build log if anyone runs this unattended. Taking the password
as a flag instead would trade the log for shell history, which is not obviously
better and is worse for the target case.

So: generated and printed, and said plainly to be a bootstrap credential. A
deployment that runs this in a pipeline should be using its own provisioning
instead. Revisit if that stops being true.
*/
let passwordNote = `
🚨 This is a bootstrap credential and it is printed above because that is the only
   place it exists — Cognito keeps no recoverable copy. It is now in this
   terminal's scrollback. Sign in, change it, and do not paste it where logs are
   kept. Running this again mints a new one.`

let signInDetails = (~providerId: string, ~email: string, ~password: string, ~group: string) =>
  `
The first administrator is ready.

  provider   ${providerId}
  sign in as ${email}
  password   ${password}
  group      ${group}
${passwordNote}

This script bootstraps the first account only, which is the one that cannot be
made through a signed-in session because there is no signed-in session yet. The
rest of the cast is a list rather than a command: declare it in
.reventless/users.yaml and run \`pnpm exec provision-accounts\`.`

let run = async (): result<unit, string> =>
  // argv[0] is node, argv[1] this script.
  switch parseArgs(NodeProcess.argv->Array.slice(~start=2, ~end=NodeProcess.argv->Array.length)) {
  | Error(_) as e => e
  | Ok(args) if args.help =>
    Console.log(usage)
    Ok()
  | Ok(args) =>
    // The address is checked before the provider is resolved: it costs nothing,
    // while resolving may shell out to Pulumi, and a run missing both arguments
    // should say the cheap thing rather than fail on a stack lookup it never
    // needed.
    switch args.email {
    | None => Error("--email is required — it is the address the administrator signs in with")
    | Some(email) =>
      switch ProvisionProvider.resolve(~given=args.providerId, ~stack=args.stack) {
      | Error(_) as e => e
      | Ok((providerId, source)) =>
        Console.log(`provider ${providerId} (from ${source->ProvisionProvider.describe})`)
        switch await checkPoolAcceptsEmail(~providerId) {
        | Error(_) as e => e
        | Ok() =>
          let group = Reventless.AdminGroup.name
          let password = Reventless.Util_Password.generate()
          await ensureGroup(~providerId, ~group)
          await ensureUser(~providerId, ~email)
          await setPassword(~providerId, ~email, ~password)
          await addToGroup(~providerId, ~email, ~group)
          Console.log(signInDetails(~providerId, ~email, ~password, ~group))
          Ok()
        }
      }
    }
  }

/**
🚨 **Catches thrown exceptions, not only `Error` results** — the reason
[ProvisionIdentity.main] gives. Without it an SDK failure escapes an async
function nothing awaits and Node reports `UnhandledPromiseRejection ...
"#<Object>"`, naming neither the call that failed nor why.
*/
let main = async () =>
  switch await run() {
  | Ok() => ()
  | Error(message) =>
    Console.error(`provision-admin: ${message}`)
    NodeProcess.exit(1)
  | exception exn =>
    Console.error(`provision-admin: ${Util_AwsError.describe(exn)}`)
    NodeProcess.exit(1)
  }

// 🚨 **No top-level call.** `../run-provision-admin.mjs` invokes [main]; this
// module only defines it. A module that ran itself on import could not be
// imported by a test — which is how a guard that could never match once shipped
// in the sibling script.
