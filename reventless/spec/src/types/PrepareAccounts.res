/***
Make a platform's accounts manifest ready to use.

```
pnpm exec prepare-accounts
```

Finds `.reventless/users.yaml` — copying the package's committed
`users.example.yaml` into place when there is none — validates it, and generates a
password into every field left empty.

🚨 **On the local platform this is the whole of provisioning.** The manifest *is*
the user store there: the in-memory auth adapter hydrates from it at startup, so
once every account has a password there is nothing left to create. On AWS the
accounts still have to be made in a pool, which is `provision-accounts` in
`reventless-aws`.

Here, rather than as a flag on that command, because it belongs to neither
platform. A local developer reaching it through an AWS package's binary would be
the only thing about this half that mentioned AWS at all — and the local platform
does not depend on `reventless-aws`, so for a project that never deploys it would
not resolve.

It creates nothing, contacts nothing, and needs no credentials. Re-running is safe:
a password already in the file is never replaced.
*/

type args = {
  file: option<string>,
  help: bool,
}

let parseArgs = (argv: array<string>): result<args, string> => {
  let acc = ref(Ok({file: None, help: false}))
  let i = ref(0)
  let count = argv->Array.length
  while i.contents < count {
    let flag = argv->Array.getUnsafe(i.contents)
    let value = argv->Array.get(i.contents + 1)
    switch (acc.contents, flag, value) {
    | (Error(_), _, _) => i := count
    | (Ok(a), "--file", Some(v)) =>
      acc := Ok({...a, file: Some(v)})
      i := i.contents + 2
    | (Ok(a), "--help", _) | (Ok(a), "-h", _) =>
      acc := Ok({...a, help: true})
      i := i.contents + 1
    | (Ok(_), "--file", None) => acc := Error(`${flag} needs a value`)
    | (Ok(_), unknown, _) => acc := Error(`unknown argument "${unknown}"`)
    }
  }
  acc.contents
}

let usage = `
Make a platform's accounts manifest ready to use.

  --file <path>   The manifest. Defaults to .reventless/users.yaml relative to the
                  working directory, which is where every platform keeps it. A
                  named path is read, never created.

Copies ${AccountsManifest.templateName} into place when there is no manifest yet,
then generates a password into every empty field. Creates no accounts and needs no
credentials — on the local platform that is all provisioning is. A password already
in the file is never replaced.
`

/** The cast, as the file now declares it. Printed on a fresh copy because that is
  the moment somebody should read it: on AWS the next command turns each of these
  into a real account in a real pool. */
let castNote = (entries: array<AccountsManifest.entry>): string =>
  entries
  ->Array.map(entry =>
    `  ${entry.username}${entry.groups->Array.length == 0
        ? ""
        : `  [${entry.groups->Array.join(", ")}]`}`
  )
  ->Array.join("\n")

let run = (): result<unit, string> =>
  // argv[0] is node, argv[1] this script.
  switch parseArgs(NodeProcess.argv->Array.slice(~start=2, ~end=NodeProcess.argv->Array.length)) {
  | Error(_) as e => e
  | Ok(args) if args.help =>
    Console.log(usage)
    Ok()
  | Ok(args) =>
    switch AccountsManifest.locate(~given=?args.file, ()) {
    | Error(_) as e => e
    | Ok(located) =>
      let file = located->AccountsManifest.pathOf
      switch located {
      | SeededFrom(_, template) => Console.log(`manifest ${file} (new, copied from ${template})`)
      | Declared(_) => Console.log(`manifest ${file}`)
      }
      switch AccountsManifest.prepare(~path=file) {
      | Error(message) => Error(`${file}: ${message}`)
      | Ok([]) => Error(`${file} declares no accounts`)
      | Ok(prepared) =>
        let generated = prepared->Array.filter(p => p.passwordGenerated)->Array.length
        Console.log(
          `accounts ${prepared
            ->Array.length
            ->Int.toString} declared, ${generated->Int.toString} password(s) generated\n\n${castNote(
              prepared->Array.map(p => p.entry),
            )}`,
        )
        Ok()
      }
    }
  }

let main = async () =>
  switch run() {
  | Ok() => ()
  | Error(message) =>
    Console.error(`prepare-accounts: ${message}`)
    NodeProcess.exit(1)
  }
