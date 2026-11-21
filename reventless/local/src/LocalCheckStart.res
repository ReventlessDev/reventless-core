// `check-start`: whether an app would start, without starting it.
//
// Runs the app's own `Main` in check mode, so the plugins, their order and the host UI bundle are
// exactly what a start would use, and every plugin is built by the same builder. What the builder
// refuses at boot it refuses here, with the same message. Check mode keeps the start from going
// further than building: the store is in memory, the address check is skipped, and no server,
// registry entry, event tap or idle timer is started.

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

let usage = `Usage: check-start [--json] [<mainModule>]

  <mainModule>  the app's compiled start module; default src/Main.res.mjs
  --json        print the verdict as one JSON object on stdout:
                {"starts": true}, or {"starts": false, "refusal": {…}} with the
                message, the component and each finding with its code

  Run from the app's local platform package, after rescript build. Builds every
  plugin the way a start does, in memory, and serves nothing. Exits 0 when the
  app would start, 1 with the reason when it would not.`

type args = {mainModule?: string, json?: bool}

let parseArgs = (argv: array<string>): result<args, string> =>
  Reventless.CliArgs.parse(~bools=["json"], argv)
  ->Result.flatMap(a => a->Reventless.CliArgs.atMost(1))
  ->Result.map(a => {
    mainModule: ?(a->Reventless.CliArgs.positionals->Array.get(0)),
    json: ?(a->Reventless.CliArgs.bool("json") ? Some(true) : None),
  })

let cli: Reventless.CliArgs.cli<args> = {bin: "check-start", usage, parse: parseArgs}

/** The start module's path: the argument resolved from the working directory, else the
    conventional `src/Main.res.mjs`. */
let mainModulePath = (~mainModule: option<string>): string =>
  NodePath.resolve([mainModule->Option.getOr(NodePath.join(["src", "Main.res.mjs"]))])

/** What a failed start says: the thrown message, else that nothing was said. */
let reasonOf = (e: JsExn.t): string => e->JsExn.message->Option.getOr("it threw without a message")

/** What `--json` prints for an app that starts. */
let startsJson = (): JSON.t =>
  Dict.fromArray([("starts", JSON.Encode.bool(true))])->JSON.Encode.object

/** What `--json` prints for an app that would not start: the refusal the error carries, or,
    for an error that carries none, its message under the code `unknown`. */
let refusedJson = (~refusal: option<Reventless.StartRefusal.t>, reason: string): JSON.t =>
  Dict.fromArray([
    ("starts", JSON.Encode.bool(false)),
    (
      "refusal",
      switch refusal {
      | Some(r) => r->Reventless.StartRefusal.toJson
      | None => Reventless.StartRefusal.unknownToJson(reason)
      },
    ),
  ])->JSON.Encode.object

let wouldNotStart = (
  ~json: bool,
  ~refusal: option<Reventless.StartRefusal.t>=?,
  reason: string,
) => {
  if json {
    Console.log(refusedJson(~refusal, reason)->JSON.stringify)
  } else {
    Console.error(`check-start: the app would not start: ${reason}`)
  }
  NodeProcess.exit(1)
}

/** A failed start, reported with the refusal its error carries. */
let refused = (~json: bool, e: JsExn.t) =>
  wouldNotStart(~json, ~refusal=?Reventless.StartRefusal.ofError(e), reasonOf(e))

/** Sets the environment check mode reads. Before the import, because the platform reads its
    backend and log level when its module is applied. */
let enterCheckMode = (~env=NodeProcess.env, ~json=false, ()) => {
  env->Dict.set(envVar, "1")
  env->Dict.set("REVENTLESS_LOCAL_BACKEND", "memory")
  // The local platform logs at Debug by default; a check reports only what goes wrong. With
  // `--json` the verdict is the only line on stdout, where a log writes its JSON lines too.
  switch env->Dict.get("LOG_LEVEL") {
  | Some(_) => ()
  | None => env->Dict.set("LOG_LEVEL", json ? "silent" : "warn")
  }
}

let main = () =>
  Reventless.CliArgs.run(cli, async ({?mainModule, ?json}) => {
    let json = json->Option.getOr(false)
    let path = mainModulePath(~mainModule)
    if !NodeFs.existsSync(path) {
      wouldNotStart(~json, `${path} not found — run \`rescript build\` first.`)
    }
    enterCheckMode(~json, ())
    onUncaughtException(e => refused(~json, e))
    onUnhandledRejection(e => refused(~json, e))
    switch await dynImport(NodeUrl.pathToFileURL(path)["href"]) {
    | exception JsExn(e) => refused(~json, e)
    | _ =>
      // The build schedules part of its wiring as callbacks; one more turn of the event loop
      // lets them run, so a failure there is reported rather than cut off by the exit.
      await Promise.make((resolve, _) => setTimeout(() => resolve(), 0)->ignore)
      if json {
        Console.log(startsJson()->JSON.stringify)
      } else {
        Console.log("check-start: the app starts.")
      }
      NodeProcess.exit(0)
    }
  })
