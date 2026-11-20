// Where the local platforms running on this machine say who they are: one JSON
// entry per run under `<cwd>/.reventless/running/<domainPort>.json`, removed on
// exit. Keyed by domain port because the pair that broke is two platforms of the
// SAME app in one directory. Paths are absolute — `./.reventless/local.db` names
// a different file in every app. `LocalSeedTarget` turns this into the answer to
// "which platform do you mean".

// What a reader can DO with the store, not which module implements it. A
// `:memory:` SQLite file reports `memory`. A word this build does not know reads
// as `OtherStore`, keeping the word: `list` deletes an entry it cannot decode, so
// a newer platform's store kind must not make it vanish.
@unboxed @schema
type storeKind =
  | @as("sqlite") SqliteStore
  | @as("memory") MemoryStore
  | @as("postgres") PostgresStore
  | OtherStore(string)

@schema
type store = {
  kind: storeKind,
  // Some only for a store this machine can open by name.
  path?: string,
}

/** Where the webhook doors are served, and the file that names each door and the secret it
    signs with (`LocalWebhookSecrets`). */
@schema
type webhooks = {
  base: string,
  // Absent when the platform has no `.reventless/` to keep the file in.
  secrets?: string,
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
  // Where the NDJSON event tap is served, when it is. Must stay optional: `list`
  // DELETES an entry it cannot decode, so requiring it would silently hide every
  // platform from an older build. Absent ⇒ stdout only.
  tapPort?: int,
  // Where the log feed is served, when it is: the platform's recent and live log
  // records. Optional for the same reason as `tapPort`.
  logPort?: int,
  // Where the platform API is served: its own port when the platform serves two
  // APIs, else the same endpoint as `endpoint`. Optional for the same reason.
  platformEndpoint?: string,
  // Where a caller posts to the inbound translations' doors. Optional for the same reason.
  webhooks?: webhooks,
  // Where the running stand-ins are listed and driven, once they run. Optional for the same reason.
  standins?: string,
}

// Threaded rather than read at each use, so tests need not move the process.
let runningDir = (~cwd=NodeProcess.cwd(), ()): string =>
  NodePath.join([cwd, ".reventless", "running"])

let entryPath = (~port: int, ~cwd=NodeProcess.cwd()): string =>
  NodePath.join([runningDir(~cwd, ()), `${port->Int.toString}.json`])

// The package name, for the prompt line — port alone reads as an arbitrary
// number when the platforms are different apps.
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

/** Signal `0` signals nothing — it runs the existence/permission checks and
    throws when either fails. By pid, so a wedged platform is pruned too. */
let alive = (pid: int): bool =>
  try {
    NodeProcess.kill(pid, 0)
    true
  } catch {
  | _ => false
  }

let readEntry = (path: string): option<entry> =>
  try Some(
    path->NodeFs.readFileSync->JSON.parseOrThrow->Reventless.Util_Sury.fromJson(entrySchema),
  ) catch {
  | _ => None
  }

/** Every platform running here, lowest port first. Removal on exit is
    best-effort (`kill -9`), so a dead entry is deleted here, on read. */
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

/** Writes one entry and returns its path. Split from {!register} so a test can
    populate a registry without installing exit handlers in the runner. */
let write = (
  ~port: int,
  ~endpoint: string,
  ~loginEndpoint: string,
  ~store: store,
  ~tapPort: option<int>=?,
  ~platformEndpoint: option<string>=?,
  ~webhooks: option<webhooks>=?,
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
    ?tapPort,
    ?platformEndpoint,
    ?webhooks,
  }
  try {
    NodeFs.mkdirSync(runningDir(~cwd, ()), {recursive: true})
    NodeFs.writeFileSync(
      path,
      entry->Reventless.Util_Sury.toJson(entrySchema)->JSON.stringify(~space=2),
    )
  } catch {
  // A platform that cannot announce itself must still serve.
  | _ => ()
  }
  path
}

/** Adds the tap port to an entry already written.

    Separate from {!write} because the socket binds asynchronously: the entry is
    published as soon as the servers are up, and this fills in the port once
    `listen` calls back. So the entry only ever names a port that is genuinely
    listening. A no-op when there is no entry to update. */
let publishTapPort = (~port: int, ~tapPort: int, ~cwd=NodeProcess.cwd()): unit => {
  let path = entryPath(~port, ~cwd)
  switch readEntry(path) {
  | None => ()
  | Some(entry) =>
    try NodeFs.writeFileSync(
      path,
      {...entry, tapPort}->Reventless.Util_Sury.toJson(entrySchema)->JSON.stringify(~space=2),
    ) catch {
    | _ => ()
    }
  }
}

/** Adds where the stand-ins are served to an entry already written, once they run. */
let publishStandins = (~port: int, ~url: string, ~cwd=NodeProcess.cwd()): unit => {
  let path = entryPath(~port, ~cwd)
  switch readEntry(path) {
  | None => ()
  | Some(entry) =>
    try NodeFs.writeFileSync(
      path,
      {...entry, standins: url}->Reventless.Util_Sury.toJson(entrySchema)->JSON.stringify(~space=2),
    ) catch {
    | _ => ()
    }
  }
}

/** Adds the log feed's port to an entry already written, once its socket is
    bound; see {!publishTapPort}. */
let publishLogPort = (~port: int, ~logPort: int, ~cwd=NodeProcess.cwd()): unit => {
  let path = entryPath(~port, ~cwd)
  switch readEntry(path) {
  | None => ()
  | Some(entry) =>
    try NodeFs.writeFileSync(
      path,
      {...entry, logPort}->Reventless.Util_Sury.toJson(entrySchema)->JSON.stringify(~space=2),
    ) catch {
    | _ => ()
    }
  }
}

/** Publishes this process, and unpublishes it on the way out. Both paths are
    needed: `exit` is sync-only, and registering a signal handler suppresses
    Node's default exit, so each signal must leave explicitly. */
let register = (
  ~port: int,
  ~endpoint: string,
  ~loginEndpoint: string,
  ~store: store,
  ~tapPort: option<int>=?,
  ~platformEndpoint: option<string>=?,
  ~webhooks: option<webhooks>=?,
): unit => {
  let path = write(
    ~port,
    ~endpoint,
    ~loginEndpoint,
    ~store,
    ~tapPort?,
    ~platformEndpoint?,
    ~webhooks?,
  )
  NodeProcess.onExit(_ => removeQuietly(path))
  NodeProcess.onSignal(SIGINT, () => {
    removeQuietly(path)
    NodeProcess.exit(130)
  })
  NodeProcess.onSignal(SIGTERM, () => {
    removeQuietly(path)
    NodeProcess.exit(143)
  })
}
