// Where the local platforms running on this machine say who they are.
//
// A platform's store is otherwise invisible from outside its own process, so
// every tool that wants to act on "the" store — `seed`, `seed:reset`, a `sqlite3`
// poke — has to guess from its own environment. The guess is right exactly while
// there is one platform and wrong exactly when there are two, which is the case
// the tools exist for: a hand-started `pnpm run serve` on `local.db` beside the
// VS Code runner's child on `runner.db`, same app, same directory. Both then
// report success against different databases — a reset that empties an unserved
// store, and a seed that refuses because the served one is full.
//
// So a platform publishes itself instead: one JSON entry per run, next to the
// store it opened, removed on the way out. `LocalSeedTarget` turns that into the
// answer to "which platform do you mean".
//
// ── Why one file per port ──────────────────────────────────────────────────
//
// The pair that broke is two platforms of the SAME app in the SAME package
// directory, which is precisely what a single `platform.json` cannot represent.
// The domain port is what already distinguishes them (`REVENTLESS_DOMAIN_PORT`,
// added so the runner could start one child per app without colliding), so it
// names the file.
//
// ── Why the path is absolute ───────────────────────────────────────────────
//
// `./.reventless/local.db` names a different file in every app. Relative to the
// writer's cwd it is unambiguous and outside it means nothing, so the entry
// carries the path `BackendState` resolved, not the env string it came from.

@schema
type store = {
  // "sqlite" | "memory" | "postgres" — what a reader can DO with this platform's
  // store, not which module implements it. A `:memory:` SQLite file reports
  // "memory": it has nothing on disk to open, which is the only distinction a
  // tool acting from outside can act on.
  kind: string,
  // Some only for a store this machine can open by name.
  path: option<string>,
}

@schema
type entry = {
  app: string,
  port: int,
  pid: int,
  endpoint: string,
  loginEndpoint: string,
  store: store,
  startedAt: string,
}

// `~cwd` is the directory the platform was started from, which is where its
// `.reventless/` already lives. Threaded rather than read at each use so the
// tests can exercise a registry without moving the whole process.
let runningDir = (~cwd=NodeProcess.cwd(), ()): string =>
  NodePath.join([cwd, ".reventless", "running"])

let entryPath = (~port: int, ~cwd=NodeProcess.cwd()): string =>
  NodePath.join([runningDir(~cwd, ()), `${port->Int.toString}.json`])

// The package this platform was started from, for the prompt line. Two platforms
// of one app are told apart by port; the name is there for the case where they
// are different apps and the port alone reads as an arbitrary number.
let appName = (~cwd=NodeProcess.cwd(), ()): string => {
  let manifest = NodePath.join([cwd, "package.json"])
  let fromManifest = if NodeFs.existsSync(manifest) {
    try {
      manifest
      ->NodeFs.readFileSync
      ->JSON.parseOrThrow
      ->JSON.Decode.object
      ->Option.flatMap(d => d->Dict.get("name"))
      ->Option.flatMap(JSON.Decode.string)
    } catch {
    | _ => None
    }
  } else {
    None
  }
  fromManifest->Option.getOr(NodePath.basename(cwd))
}

let removeQuietly = (path: string): unit =>
  try NodeFs.unlinkSync(path) catch {
  | _ => ()
  }

/** Whether a process is still there. Signal `0` performs no signalling — it only
    runs the permission and existence checks and throws when either fails.

    Liveness by pid rather than by probing the endpoint keeps this synchronous,
    and prunes a wedged platform that holds its port but would never answer. */
let alive = (pid: int): bool =>
  try {
    NodeProcess.kill(pid, 0)
    true
  } catch {
  | _ => false
  }

let readEntry = (path: string): option<entry> =>
  try Some(path->NodeFs.readFileSync->JSON.parseOrThrow->S.parseJsonOrThrow(entrySchema)) catch {
  | _ => None
  }

/** Every platform currently running in this directory, oldest port first.

    Removal on exit is best-effort — a `kill -9` leaves the entry behind — so
    staleness is settled here, on read: an entry whose process is gone is deleted
    rather than reported. A reader that trusted the file would offer a platform
    nothing is serving, which is the failure this module exists to remove. */
let list = (~cwd=NodeProcess.cwd(), ()): array<entry> => {
  let dir = runningDir(~cwd, ())
  if !NodeFs.existsSync(dir) {
    []
  } else {
    let files = try NodeFs.readdirSync(dir, {withFileTypes: true}) catch {
    | _ => []
    }
    files
    ->Array.filter(d => d->NodeFs.isFile && d->NodeFs.direntName->String.endsWith(".json"))
    ->Array.filterMap(d => {
      let path = NodePath.join([dir, d->NodeFs.direntName])
      switch readEntry(path) {
      | Some(entry) if alive(entry.pid) => Some(entry)
      | _ =>
        removeQuietly(path)
        None
      }
    })
    ->Array.toSorted((a, b) => Int.compare(a.port, b.port))
  }
}

/** Writes one entry and hands back the path it wrote, without touching the
    process. Split from {!register} so a test can populate a registry without
    installing exit handlers in the test runner. */
let write = (
  ~port: int,
  ~endpoint: string,
  ~loginEndpoint: string,
  ~store: store,
  ~pid: int=NodeProcess.pid,
  ~cwd: string=NodeProcess.cwd(),
): string => {
  let path = entryPath(~port, ~cwd)
  let entry = {
    app: appName(~cwd, ()),
    port,
    pid,
    endpoint,
    loginEndpoint,
    store,
    startedAt: Date.make()->Date.toISOString,
  }
  try {
    NodeFs.mkdirSync(runningDir(~cwd, ()), {recursive: true})
    NodeFs.writeFileSync(
      path,
      entry->S.reverseConvertToJsonOrThrow(entrySchema)->JSON.stringify(~space=2),
    )
  } catch {
  // A platform that cannot announce itself must still serve. The tools fall back
  // to their endpoint default, which is what they did before this existed.
  | _ => ()
  }
  path
}

/** Publishes this process, and arranges for it to stop being published.

    Both shutdown paths are covered because they are not the same event: `exit`
    fires with the process already committed to leaving and may only do
    synchronous work, while `SIGINT`/`SIGTERM` fire before that decision — and
    registering a signal handler at all is what suppresses Node's default exit,
    so each one has to leave explicitly (128 + signal number, as a shell reports
    it). */
let register = (~port: int, ~endpoint: string, ~loginEndpoint: string, ~store: store): unit => {
  let path = write(~port, ~endpoint, ~loginEndpoint, ~store)
  NodeProcess.onExit(_ => removeQuietly(path))
  NodeProcess.onSignal(#SIGINT, () => {
    removeQuietly(path)
    NodeProcess.exit(130)
  })
  NodeProcess.onSignal(#SIGTERM, () => {
    removeQuietly(path)
    NodeProcess.exit(143)
  })
}
