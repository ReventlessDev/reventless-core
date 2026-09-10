/***
Turn a declared cast of accounts into working sign-ins.

`provision-admin` makes the *first* administrator, which is the account that
cannot be made from a signed-in session because there is no signed-in session yet.
This one makes a declared list of accounts instead.

🚨 **Neither needs the other to have run.** Both authenticate as the AWS caller,
not as a Cognito principal, so there is no bootstrap ordering between them: a
manifest declaring an entry in the administrator group stands a deployment up on
its own. The difference is where the credential ends up — `provision-admin` prints
one and keeps no copy, while this writes into the manifest, which is what
`pnpm run seed` reads. For a demo whose cast already names an administrator, this
one alone is enough.

```
pnpm exec provision-accounts
```

It reads `.reventless/users.yaml`, and knows nothing about any particular
application's cast: the manifest belongs to whoever is deploying. A demo's four
roles and a company's twelve staff are the same run. Which pool it writes to is
[ProvisionProvider]'s question, and usually needs no argument either.

🚨 **Two halves, and only the second is AWS's.** [Reventless.AccountsManifest.prepare]
validates the manifest and mints a password into every empty field, on any
platform and with no credentials — locally that is the whole of provisioning,
because there the manifest *is* the user store. This script then applies the
prepared manifest to a Cognito pool. That first half is its own bin,
`prepare-accounts`, so a platform that never deploys to AWS can reach it without
depending on this package.

Re-running is safe and is the normal case — an operator adding one account to
four. A password already in the file is never replaced; see
[Reventless.AccountsManifest.applyFills] for why that rule is the whole of the
write-back's safety.
*/

open AwsSdk

module Cognito = CognitoIdentityServiceProvider
module Manifest = Reventless.AccountsManifest

// ── Arguments ────────────────────────────────────────────────────────────────

type args = {
  providerId: option<string>,
  stack: option<string>,
  file: option<string>,
  help: bool,
}

/** Parsed rather than positional, and unknown flags are an error — the reason
  [ProvisionAdmin.parseArgs] gives, which lands harder here: a typo'd
  `--provider-id` would fall through to the environment and create the whole cast
  in a *different pool* than the operator named. */
let parseArgs = (argv: array<string>): result<args, string> => {
  let acc = ref(Ok({providerId: None, stack: None, file: None, help: false}))
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
    | (Ok(a), "--file", Some(v)) =>
      acc := Ok({...a, file: Some(v)})
      i := i.contents + 2
    | (Ok(a), "--help", _) | (Ok(a), "-h", _) =>
      acc := Ok({...a, help: true})
      i := i.contents + 1
    | (Ok(_), "--provider-id", None) | (Ok(_), "--file", None) | (Ok(_), "--stack", None) =>
      acc := Error(`${flag} needs a value`)
    | (Ok(_), unknown, _) => acc := Error(`unknown argument "${unknown}"`)
    }
  }
  acc.contents
}

let usage = `
Turn a declared cast of accounts into working sign-ins.

  --provider-id <id>   The identity provider to create the accounts in. Usually
                       omitted: it falls back to ${ProvisionProvider.envKey},
                       then to the identityProviderId exported by the selected
                       Pulumi stack — which every deployment exports, whether it
                       created the pool or was handed one.
  --stack <name>       Read that output from this stack instead of the selected
                       one. The run always names the stack it used.
  --file <path>        The manifest. Defaults to .reventless/users.yaml relative
                       to the working directory, which is where both platforms
                       keep it.

For every entry: ensures the groups it names, ensures the account, sets a
permanent password, and applies the memberships. Generated passwords and the ids
the pool mints are written back into the manifest, so the seed client can read
them without anyone retyping a UUID.

A password already in the manifest is never replaced. Region and credentials come
from the environment, as for any AWS SDK call.
`

// ── Preflight ────────────────────────────────────────────────────────────────

let looksLikeEmail = (username: string): bool =>
  username->String.includes("@") && username->String.includes(".")

/**
Refuse a pool this cast could never sign in to.

The mirror of [ProvisionAdmin.checkPoolAcceptsEmail], and it has to run the other
way round: that script is handed an address and asks whether the pool takes one,
while a manifest usually names plain usernames — `shopper`, `merch` — and the
question is whether the pool will accept *those*. A pool created with
`UsernameAttributes: [email]` will not, and the accounts it makes instead are
correctly created and unable to authenticate.

Checked for every entry before anything is created, so a manifest that cannot work
costs nothing rather than half a cast.
*/
let checkPoolAcceptsUsernames = async (~providerId: string, ~usernames: array<string>): result<
  unit,
  string,
> =>
  switch await ProvisionCognito.usernameAttributes(~providerId) {
  | Error(_) as e => e
  | Ok(attributes) =>
    let signsInOnEmail = attributes->Array.includes("email")
    let unusable = signsInOnEmail ? usernames->Array.filter(u => !looksLikeEmail(u)) : []
    if unusable->Array.length == 0 {
      Console.log(
        `pool     signs in on ${attributes->Array.length == 0
            ? "username"
            : attributes->Array.join(", ")}`,
      )
      Ok()
    } else {
      Error(
        `pool "${providerId}" signs in on ${attributes->Array.join(
            ", ",
          )}, so ${unusable->Array.join(
            ", ",
          )} could never authenticate. The sign-in attribute is fixed at pool creation and no update can change it — either name these accounts by address in the manifest, or provision them in a pool that signs in on a username.`,
      )
    }
  }

// ── Applying ─────────────────────────────────────────────────────────────────

let describe = (outcome: ProvisionCognito.outcome) =>
  switch outcome {
  | Created => "created"
  | AlreadyPresent => "already present"
  }

/** Every group the manifest names, made once rather than once per member.

  The description says where the group came from because a pool outlives the
  deployment that seeded it, and an operator meeting an undocumented group in the
  console has no other way to find out. */
let ensureGroups = async (~providerId: string, ~entries: array<Manifest.entry>): unit => {
  let named = []
  entries->Array.forEach(entry =>
    entry.groups->Array.forEach(group =>
      if !(named->Array.includes(group)) {
        named->Array.push(group)
      }
    )
  )
  for index in 0 to named->Array.length - 1 {
    let group = named->Array.getUnsafe(index)
    let outcome = await ProvisionCognito.ensureGroup(
      ~providerId,
      ~group,
      ~description="Declared in a Reventless accounts manifest",
    )
    Console.log(`group    ${group} (${outcome->describe})`)
  }
}

/**
One account: the entry, applied.

The password is set unconditionally rather than only for an account this run
created — the same reason `provision-admin` does it, arriving at a manifest: the
file is the record of what the credential *is*, so an account whose password
drifted from the file is exactly the case a re-run is expected to fix.

Returns the id the pool minted, which is the value the manifest cannot know until
the account exists and which nobody should be pasting by hand.
*/
let applyEntry = async (~providerId: string, ~entry: Manifest.entry): option<string> => {
  let attributes: array<Cognito.AdminCreateUserCommand.attributeType> = looksLikeEmail(
    entry.username,
  )
    ? [{name: "email", value: entry.username}, {name: "email_verified", value: "true"}]
    : []
  let outcome = await ProvisionCognito.ensureUser(
    ~providerId,
    ~username=entry.username,
    ~attributes,
  )
  Console.log(`user     ${entry.username} (${outcome->describe})`)
  await ProvisionCognito.setPassword(
    ~providerId,
    ~username=entry.username,
    ~password=entry.password,
  )
  for index in 0 to entry.groups->Array.length - 1 {
    let group = entry.groups->Array.getUnsafe(index)
    await ProvisionCognito.addToGroup(~providerId, ~username=entry.username, ~group)
    Console.log(`member   ${entry.username} in ${group}`)
  }
  await ProvisionCognito.subOf(~providerId, ~username=entry.username)
}

// ── Main ─────────────────────────────────────────────────────────────────────

/**
🚨 **The passwords are in the manifest, not in this output, and that is the whole
point of the write-back.**

`provision-admin` prints its one credential because there is nowhere else for it
to live. A cast of four has somewhere: the file the seed client already reads to
sign in. Printing them here would put every account's password in scrollback and
in any build log, and buy nothing — whoever needs them can read the file they
already have.
*/
let manifestNote = (~file: string) =>
  `
🚨 Generated passwords were written into ${file}. They are not printed here
   because that file is where they are read from — by you and by \`pnpm run seed\`.
   It is gitignored on every platform; keep it that way. These are bootstrap
   credentials for a deployment, not secrets to reuse anywhere real.`

let run = async (): result<unit, string> =>
  // argv[0] is node, argv[1] this script.
  switch parseArgs(NodeProcess.argv->Array.slice(~start=2, ~end=NodeProcess.argv->Array.length)) {
  | Error(_) as e => e
  | Ok(args) if args.help =>
    Console.log(usage)
    Ok()
  | Ok(args) =>
    switch Manifest.locate(~given=?args.file, ()) {
    | Error(_) as e => e
    | Ok(located) =>
      let file = located->Manifest.pathOf
      switch located {
      | SeededFrom(_, template) => Console.log(`manifest ${file} (new, copied from ${template})`)
      | Declared(_) => ()
      }
      switch Manifest.prepare(~path=file) {
      | Error(message) => Error(`${file}: ${message}`)
      | Ok([]) => Error(`${file} declares no accounts`)
      | Ok(prepared) =>
        let generated = prepared->Array.filter(p => p.passwordGenerated)->Array.length
        Console.log(
          `manifest ${file} (${prepared
            ->Array.length
            ->Int.toString} accounts, ${generated->Int.toString} password(s) generated)`,
        )
        let entries = prepared->Array.map(p => p.entry)
        switch ProvisionProvider.resolve(~given=args.providerId, ~stack=args.stack) {
        | Error(message) =>
          Error(
            `${message}. To fill in the manifest without creating anything, run prepare-accounts`,
          )
        | Ok((providerId, source)) =>
          Console.log(`provider ${providerId} (from ${source->ProvisionProvider.describe})`)
          switch await checkPoolAcceptsUsernames(
            ~providerId,
            ~usernames=entries->Array.map(e => e.username),
          ) {
          | Error(_) as e => e
          | Ok() =>
            await ensureGroups(~providerId, ~entries)
            let fills = []
            for index in 0 to entries->Array.length - 1 {
              let entry = entries->Array.getUnsafe(index)
              let userId = await applyEntry(~providerId, ~entry)
              fills->Array.push({Manifest.index, password: None, userId})
            }
            switch Manifest.fillFile(~path=file, ~fills) {
            | Error(message) => Error(`${file}: ${message}`)
            | Ok(report) =>
              let corrected = report->Array.filter(r => r.userIdWritten)->Array.length
              Console.log(
                `manifest ${file} (${corrected->Int.toString} id(s) written back)${manifestNote(
                    ~file,
                  )}`,
              )
              Ok()
            }
          }
        }
      }
    }
  }

/**
🚨 **Catches thrown exceptions, not only `Error` results** — the reason
[ProvisionAdmin.main] gives. Without it an SDK failure escapes an async function
nothing awaits and Node reports `UnhandledPromiseRejection ... "#<Object>"`,
naming neither the call that failed nor why.
*/
let main = async () =>
  switch await run() {
  | Ok() => ()
  | Error(message) =>
    Console.error(`provision-accounts: ${message}`)
    NodeProcess.exit(1)
  | exception exn =>
    Console.error(`provision-accounts: ${Util_AwsError.describe(exn)}`)
    NodeProcess.exit(1)
  }

// 🚨 **No top-level call.** `../run-provision-accounts.mjs` invokes [main]; this
// module only defines it. A module that ran itself on import could not be
// imported by a test.
