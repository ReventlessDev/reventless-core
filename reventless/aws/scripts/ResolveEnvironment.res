/***
Which environment a push, a tag or a pull request deploys to, from the app's
`environments.yaml`.

```
pnpm exec resolve-environment --ref refs/heads/test
pnpm exec resolve-environment --pull-request 7 --base dev
```

Prints `key=value` lines, so the deploy workflow appends them to
`$GITHUB_OUTPUT` as they are:

```
matched=true
environment=test
stack=test
purpose=test
```

Nothing matched is an answer, not a failure: `matched=false` and exit 0, so a push
to a branch no environment names deploys nowhere and says so. The workflow asks
only when the file exists; without it the stack is the branch, as it always was.
*/

type request =
  | Push(string)
  | PullRequest({number: int, base: string, draft: bool})

type args = {
  file: option<string>,
  manifest: option<string>,
  request: request,
}

let parseArgs = (argv: array<string>): result<args, string> =>
  Reventless.CliArgs.parse(
    ~strings=["file", "manifest", "ref", "pull-request", "base"],
    ~bools=["draft"],
    argv,
  )
  ->Result.flatMap(Reventless.CliArgs.noPositionals)
  ->Result.flatMap(a => {
    let string = name => a->Reventless.CliArgs.string(name)
    let request = switch (string("ref"), string("pull-request"), string("base")) {
    | (Some(ref), None, None) => Ok(Push(ref))
    | (None, Some(number), Some(base)) =>
      switch Int.fromString(number) {
      | Some(number) => Ok(PullRequest({number, base, draft: a->Reventless.CliArgs.bool("draft")}))
      | None => Error(`--pull-request takes a number, not "${number}"`)
      }
    | (None, Some(_), None) => Error("--pull-request needs --base, the branch it targets")
    | (None, None, None) => Error("say what deploys: --ref, or --pull-request with --base")
    | _ => Error("--ref and --pull-request are two different questions; ask one")
    }
    request->Result.map(request => {file: string("file"), manifest: string("manifest"), request})
  })

let usage = `
Usage: resolve-environment (--ref <ref> | --pull-request <n> --base <branch> [--draft])
                           [--file <path>] [--manifest <path>]

Which environment of the app's environments.yaml a deploy goes to.

  --ref <ref>            A push or a tag: refs/heads/<branch> or refs/tags/<tag>.
  --pull-request <n>     A pull request, by number ...
  --base <branch>        ... and the branch it targets.
  --draft                The pull request is a draft.
  --file <path>          The environments file. Defaults to ${Reventless.Environments.fileName}
                         beside the deploy manifest.
  --manifest <path>      The deploy manifest. Defaults to ${DeployManifest.defaultFile}
                         in the working directory.

Prints matched, environment, stack and purpose as key=value lines; a deploy that
matches nothing prints matched=false and exits 0.
`

/** The lines printed for a request, from the environments already read. */
let answer = (environments: Reventless.Environments.t, request: request): array<string> => {
  let resolved = switch request {
  | Push(ref) =>
    ref
    ->Reventless.Environments.refOf
    ->Option.flatMap(ref => environments->Reventless.Environments.resolve(ref))
  | PullRequest({number, base, draft}) =>
    environments->Reventless.Environments.resolvePullRequest(~base, ~number, ~draft)
  }
  switch resolved {
  | Some({name, stack, purpose}) => [
      "matched=true",
      `environment=${name}`,
      `stack=${stack}`,
      `purpose=${purpose->Reventless.Environments.purposeName}`,
    ]
  | None => ["matched=false"]
  }
}

let run = (args: args): result<array<string>, string> => {
  let file = switch args.file {
  | Some(file) => file
  | None =>
    Reventless.Environments.pathBeside(
      ~manifest=args.manifest->Option.getOr(
        NodePath.join([NodeProcess.cwd(), DeployManifest.defaultFile]),
      ),
    )
  }
  if !NodeFs.existsSync(file) {
    Error(
      `no environments file at ${file}. Without one every branch deploys to the stack of its own name, and there is nothing to resolve; --file names another path.`,
    )
  } else {
    file
    ->Reventless.Environments.parseFile
    ->Result.map(environments => answer(environments, args.request))
    ->Result.mapError(message =>
      `${file}: ${message}. The deploy reads any file of this name beside the deploy manifest as its environments; a file kept there for something else needs another name, or the workflow's environments input pointed elsewhere.`
    )
  }
}

let cli: Reventless.CliArgs.cli<args> = {bin: "resolve-environment", usage, parse: parseArgs}

let main = () =>
  Reventless.CliArgs.run(cli, async args =>
    switch run(args) {
    | Ok(lines) => lines->Array.forEach(line => Console.log(line))
    | Error(message) =>
      Console.error(`resolve-environment: ${message}`)
      NodeProcess.exit(1)
    }
  )

// No top-level call: `../run-resolve-environment.mjs` invokes [main], so a test can
// import this module.
