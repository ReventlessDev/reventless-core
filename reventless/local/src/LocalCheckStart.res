// `check-start`: whether an app would start, without starting it.
//
// Runs the app's own `Main` in check mode, so the plugins, their order and the host UI bundle are
// exactly what a start would use, and every plugin is built by the same builder. What the builder
// refuses at boot it refuses here, with the same message. Check mode keeps the start from going
// further than building: the store is in memory, the address check is skipped, and no server,
// registry entry, event tap or idle timer is started. See
// docs/plans/a-decision-reads-its-own-key-across-partitions.md, Phase 1.

let envVar = "REVENTLESS_CHECK_START"

/** Whether this process is checking a start rather than starting. */
let active = (~env=NodeProcess.env, ()): bool =>
  switch env->Dict.get(envVar) {
  | Some(v) if v->String.trim != "" => true
  | _ => false
  }

// ── The command ──────────────────────────────────────────────────────────────

// Emitted by ReScript as a literal `import(...)`: the app's `Main` is only known at run time.
@val external dynImport: string => promise<'a> = "import"

// A failure the start throws outside the import (a callback the build scheduled) arrives here.
@val @scope("process")
external onUncaughtException: (@as("uncaughtException") _, JsExn.t => unit) => unit = "on"
@val @scope("process")
external onUnhandledRejection: (@as("unhandledRejection") _, JsExn.t => unit) => unit = "on"

let usage = `Usage: check-start [<mainModule>]

  <mainModule>  the app's compiled start module; default src/Main.res.mjs

  Run from the app's local platform package, after rescript build. Builds every
  plugin the way a start does, in memory, and serves nothing. Exits 0 when the
  app would start, 1 with the reason when it would not.`

type args = {mainModule?: string}

let parseArgs = (argv: array<string>): result<args, string> =>
  Reventless.CliArgs.parse(argv)
  ->Result.flatMap(a => a->Reventless.CliArgs.atMost(1))
  ->Result.map(a => {mainModule: ?(a->Reventless.CliArgs.positionals->Array.get(0))})

let cli: Reventless.CliArgs.cli<args> = {bin: "check-start", usage, parse: parseArgs}

/** The start module's path: the argument resolved from the working directory, else the
    conventional `src/Main.res.mjs`. */
let mainModulePath = (~mainModule: option<string>): string =>
  NodePath.resolve([mainModule->Option.getOr(NodePath.join(["src", "Main.res.mjs"]))])

/** What a failed start says: the thrown message, else that nothing was said. */
let reasonOf = (e: JsExn.t): string => e->JsExn.message->Option.getOr("it threw without a message")

let wouldNotStart = (reason: string) => {
  Console.error(`check-start: the app would not start: ${reason}`)
  NodeProcess.exit(1)
}

/** Sets the environment check mode reads. Before the import, because the platform reads its
    backend and log level when its module is applied. */
let enterCheckMode = (~env=NodeProcess.env, ()) => {
  env->Dict.set(envVar, "1")
  env->Dict.set("REVENTLESS_LOCAL_BACKEND", "memory")
  // The local platform logs at Debug by default; a check reports only what goes wrong.
  switch env->Dict.get("LOG_LEVEL") {
  | Some(_) => ()
  | None => env->Dict.set("LOG_LEVEL", "warn")
  }
}

let main = () =>
  Reventless.CliArgs.run(cli, async ({?mainModule}) => {
    let path = mainModulePath(~mainModule)
    if !NodeFs.existsSync(path) {
      wouldNotStart(`${path} not found — run \`rescript build\` first.`)
    }
    enterCheckMode()
    onUncaughtException(e => wouldNotStart(reasonOf(e)))
    onUnhandledRejection(e => wouldNotStart(reasonOf(e)))
    switch await dynImport(NodeUrl.pathToFileURL(path)["href"]) {
    | exception JsExn(e) => wouldNotStart(reasonOf(e))
    | _ =>
      // The build schedules part of its wiring as callbacks; one more turn of the event loop
      // lets them run, so a failure there is reported rather than cut off by the exit.
      await Promise.make((resolve, _) => setTimeout(() => resolve(), 0)->ignore)
      Console.log("check-start: the app starts.")
      NodeProcess.exit(0)
    }
  })
