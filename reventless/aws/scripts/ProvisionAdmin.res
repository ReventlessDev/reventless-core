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
  email: option<string>,
  help: bool,
}

/** The same variable `Platform_Stack` reads for the same value, so a shell that
  already exports it for a BYO deploy needs no second spelling here. */
let providerIdEnvKey = "REVENTLESS_IDENTITY_PROVIDER_ID"

/** Parsed rather than positional, and unknown flags are an error — the reason
  [ProvisionIdentity.parseArgs] gives, arriving somewhere worse: a typo'd
  `--email` that parsed as "absent" would be caught by the required-argument check
  below, but a typo'd `--provider-id` would fall through to the environment and
  create the administrator in a *different pool* than the operator named. */
let parseArgs = (argv: array<string>): result<args, string> => {
  let acc = ref(Ok({providerId: None, email: None, help: false}))
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
    | (Ok(a), "--email", Some(v)) =>
      acc := Ok({...a, email: Some(v)})
      i := i.contents + 2
    | (Ok(a), "--help", _) | (Ok(a), "-h", _) =>
      acc := Ok({...a, help: true})
      i := i.contents + 1
    | (Ok(_), "--provider-id", None) | (Ok(_), "--email", None) =>
      acc := Error(`${flag} needs a value`)
    | (Ok(_), unknown, _) => acc := Error(`unknown argument "${unknown}"`)
    }
  }
  acc.contents
}

let usage = `
Make the first administrator of a Reventless deployment.

  --provider-id <id>   The identity provider to create the account in. Defaults to
                       ${providerIdEnvKey}. In auto mode this is the
                       stack's own output:
                         pulumi stack output identityProviderId
  --email <address>    The address they sign in with.

Creates the "${Reventless.AdminGroup.name}" group if it is missing, the account if
it is missing, a working password, and the membership between them. Provisions
nothing that a platform stack owns. Region and credentials come from the
environment, as for any AWS SDK call.
`

// ── The password ─────────────────────────────────────────────────────────────

/** Excludes the glyphs a person confuses when retyping a printed credential —
  `l`/`I`/`1` and `O`/`0`. This password is meant to be read off a terminal once,
  and a bootstrap that fails on a misread character sends the operator back to the
  console this exists to avoid. */
let lower = "abcdefghijkmnopqrstuvwxyz"
let upper = "ABCDEFGHJKLMNPQRSTUVWXYZ"
let digits = "23456789"
let alphabet = lower ++ upper ++ digits

/** Comfortably over the 12 every Reventless pool is created with, since nobody
  has to remember it. */
let passwordLength = 24

/** `count` uniform bytes as ints.

  Via the hex encoding because that is what [NodeCrypto] exposes of a Buffer, and
  a binding returning raw byte values would be a new one added for this alone.
  Two hex digits always parse, so the fallback below is unreachable — it is there
  because the parse is *typed* as partial, not because it can fail. */
let randomInts = (count: int): array<int> => {
  let hex = NodeCrypto.randomBytes(count)->NodeCrypto.bufferToString("hex")
  Array.fromInitializer(~length=count, i =>
    hex->String.substring(~start=i * 2, ~end=i * 2 + 2)->Int.fromString(~radix=16)->Option.getOr(0)
  )
}

let charAt = (source: string, n: int): string =>
  source->String.charAt(mod(n, source->String.length))

/**
A password that satisfies the pool policy every Reventless pool is created with
(12+ characters, with a lowercase, an uppercase and a digit).

Satisfies it *by construction*: the three required classes are written into three
non-overlapping thirds of the string, so one of each is always present. The
obvious alternative — generate, test, regenerate — would leave a branch that
almost never runs and, when it did, would hand Cognito a password it refuses.
Almost-never is exactly the branch nobody has tested.
*/
let generatePassword = (): string => {
  let ints = randomInts(passwordLength + 6)
  let chars = ints->Array.slice(~start=0, ~end=passwordLength)->Array.map(n => alphabet->charAt(n))
  let third = passwordLength / 3
  [lower, upper, digits]->Array.forEachWithIndex((classAlphabet, block) => {
    let position = block * third + mod(ints->Array.getUnsafe(passwordLength + block), third)
    chars->Array.set(
      position,
      classAlphabet->charAt(ints->Array.getUnsafe(passwordLength + 3 + block)),
    )
  })
  chars->Array.join("")
}

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
let checkPoolAcceptsEmail = async (~providerId: string): result<unit, string> => {
  let described = await Cognito.DescribeUserPoolCommand.make({
    userPoolId: providerId,
  })->Cognito.DescribeUserPoolCommand.send
  switch described.userPool {
  | None => Error(`DescribeUserPool returned nothing for "${providerId}"`)
  | Some(pool) =>
    let attributes = pool.usernameAttributes->Option.getOr([])
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
}

// ── The account ──────────────────────────────────────────────────────────────

/** The group, where a stack has not already declared it.

  In auto mode this is a no-op and says so: [Platform_Stack] declares the group as
  an ordinary child of the pool it owns. On a supplied pool no stack does, because
  two stacks sharing a provider would both declare it and the second would fail on
  a name that already exists — so it is created here, beside the first
  administrator who needs it. */
let ensureGroup = async (~providerId: string, ~group: string): unit =>
  try {
    let _ = await Cognito.CreateGroupCommand.make({
      groupName: group,
      userPoolId: providerId,
      description: "Reventless administrators",
    })->Cognito.CreateGroupCommand.send
    Console.log(`group    ${group} (created)`)
  } catch {
  | exn if exn->Util_AwsError.hasCode(~code="GroupExistsException") =>
    Console.log(`group    ${group} (already present)`)
  }

/**
The account, where it is not already there.

`email_verified` is stamped true because nothing here can complete a verification
round-trip, and an unverified address leaves the account able to sign in but
unable to recover a password — a bootstrap that works once and strands its owner.

`MessageAction: "SUPPRESS"` stops Cognito emailing an invitation. The invitation
carries the temporary password this run is about to replace, so sending it would
tell the new administrator to sign in with a credential that no longer works.
*/
let ensureUser = async (~providerId: string, ~email: string): unit => {
  let attributes: array<Cognito.AdminCreateUserCommand.attributeType> = [
    {name: "email", value: email},
    {name: "email_verified", value: "true"},
  ]
  try {
    let _ = await Cognito.AdminCreateUserCommand.make({
      userPoolId: providerId,
      username: email,
      userAttributes: attributes,
      messageAction: "SUPPRESS",
    })->Cognito.AdminCreateUserCommand.send
    Console.log(`user     ${email} (created)`)
  } catch {
  | exn if exn->Util_AwsError.hasCode(~code="UsernameExistsException") =>
    Console.log(`user     ${email} (already present)`)
  }
}

/**
A password the account can actually be used with.

🚨 **The step it is easiest to leave out, and leaving it out reproduces the defect
this script exists to remove.** An administrator-created account holds a
*temporary* password and lands in `FORCE_CHANGE_PASSWORD`: the first sign-in meets
a `NEW_PASSWORD_REQUIRED` challenge, which the host UI is not known to handle. So
this sets a permanent one rather than a temporary one, and the account is
`CONFIRMED` when it returns.

Unconditional rather than skipped for an account that already exists, which is
what makes a second run useful instead of merely harmless: the operator who runs
this again is usually the one who has lost the password.
*/
let setPassword = async (~providerId: string, ~email: string, ~password: string): unit => {
  await Cognito.AdminSetUserPasswordCommand.make({
    userPoolId: providerId,
    username: email,
    password,
    permanent: true,
  })->Cognito.AdminSetUserPasswordCommand.send
  Console.log(`password (set, permanent)`)
}

/** Idempotent at the API: adding a user already in the group is not an error, so
  this needs no existence check of its own. */
let addToGroup = async (~providerId: string, ~email: string, ~group: string): unit => {
  await Cognito.AdminAddUserToGroupCommand.make({
    username: email,
    groupName: group,
    userPoolId: providerId,
  })->Cognito.AdminAddUserToGroupCommand.send
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

Adding more people is the AWS console's job for now — this script bootstraps the
first account only, which is the one that cannot be made through a signed-in
session because there is no signed-in session yet.`

let run = async (): result<unit, string> =>
  // argv[0] is node, argv[1] this script.
  switch parseArgs(NodeProcess.argv->Array.slice(~start=2, ~end=NodeProcess.argv->Array.length)) {
  | Error(_) as e => e
  | Ok(args) if args.help =>
    Console.log(usage)
    Ok()
  | Ok(args) =>
    let providerId = switch args.providerId {
    | Some(_) as given => given
    | None => NodeProcess.env->Dict.get(providerIdEnvKey)
    }
    switch (providerId, args.email) {
    | (None, _) =>
      Error(
        `--provider-id is required (or set ${providerIdEnvKey}). In auto mode it is the stack's own output: pulumi stack output identityProviderId`,
      )
    | (_, None) =>
      Error("--email is required — it is the address the administrator signs in with")
    | (Some(providerId), Some(email)) =>
      switch await checkPoolAcceptsEmail(~providerId) {
      | Error(_) as e => e
      | Ok() =>
        let group = Reventless.AdminGroup.name
        let password = generatePassword()
        await ensureGroup(~providerId, ~group)
        await ensureUser(~providerId, ~email)
        await setPassword(~providerId, ~email, ~password)
        await addToGroup(~providerId, ~email, ~group)
        Console.log(signInDetails(~providerId, ~email, ~password, ~group))
        Ok()
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
