// What the seed tools rely on when they ask "which platform do you mean".
//
// The failure these pin is not a crash: it is two tools reporting success about
// different databases. `seed:reset` emptied the store its own environment named
// while the platform served another, so the `seed` after it refused as though
// nothing had been reset. Everything here is therefore about the registry
// telling the truth — including when a platform died without cleaning up.

@@warning("-44")

open JestGlobals

let tempRoot = (): string =>
  NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "reventless-registry-"]))

// Above any real pid on macOS and Linux, so `kill(pid, 0)` reports it gone
// rather than hitting an unrelated process that happens to be running.
let deadPid = 2147483646

let sqliteStore = (path): LocalPlatformRegistry.store => {kind: "sqlite", path: Some(path)}
let memoryStore: LocalPlatformRegistry.store = {kind: "memory", path: None}

let writeAt = (~cwd, ~port, ~store, ~pid=NodeProcess.pid) =>
  LocalPlatformRegistry.write(
    ~port,
    ~endpoint=`http://localhost:${port->Int.toString}/graphql`,
    ~loginEndpoint=`http://localhost:${port->Int.toString}/__inmemory/login`,
    ~store,
    ~pid,
    ~cwd,
  )

describe("LocalPlatformRegistry", () => {
  testSync("reports a running platform with the store it opened", () => {
    let cwd = tempRoot()
    let _ = writeAt(~cwd, ~port=4000, ~store=sqliteStore("/abs/.reventless/runner.db"))

    switch LocalPlatformRegistry.list(~cwd, ())->Array.get(0) {
    | Some(entry) =>
      expect(entry.port)->toEqual(4000)
      expect(entry.endpoint)->toEqual("http://localhost:4000/graphql")
      expect(entry.store.kind)->toEqual("sqlite")
      expect(entry.store.path)->toEqual(Some("/abs/.reventless/runner.db"))
    | None => fail("expected the entry just written to be listed")
    }
  })

  // The pair that broke: same app, same directory, two platforms. A registry
  // that could only hold one of them would answer with a coin flip.
  testSync("lists both platforms in one directory, by port", () => {
    let cwd = tempRoot()
    let _ = writeAt(~cwd, ~port=4010, ~store=memoryStore)
    let _ = writeAt(~cwd, ~port=4000, ~store=sqliteStore("/abs/.reventless/runner.db"))

    let ports = LocalPlatformRegistry.list(~cwd, ())->Array.map(e => e.port)
    expect(ports)->toEqual([4000, 4010])
  })

  testSync("drops an entry whose process is gone, and deletes it", () => {
    let cwd = tempRoot()
    let path = writeAt(~cwd, ~port=4000, ~store=sqliteStore("/abs/x.db"), ~pid=deadPid)

    expect(LocalPlatformRegistry.list(~cwd, ()))->toEqual([])
    // Pruned, not merely skipped: a file that survived would be re-read (and
    // re-rejected) on every seed for the life of the working copy.
    expect(NodeFs.existsSync(path))->toEqual(false)
  })

  testSync("drops an unreadable entry rather than failing the run", () => {
    let cwd = tempRoot()
    let dir = LocalPlatformRegistry.runningDir(~cwd, ())
    NodeFs.mkdirSync(dir, {recursive: true})
    let path = NodePath.join([dir, "4000.json"])
    NodeFs.writeFileSync(path, "{ this is not json")

    expect(LocalPlatformRegistry.list(~cwd, ()))->toEqual([])
    expect(NodeFs.existsSync(path))->toEqual(false)
  })

  testSync("reads empty where no platform ever ran", () => {
    expect(LocalPlatformRegistry.list(~cwd=tempRoot(), ()))->toEqual([])
  })
})

describe("LocalSeedTarget.loginFor", () => {
  // Setting only REVENTLESS_GRAPHQL_ENDPOINT used to leave the login round-trip
  // on :4000 — seeding one platform through another's front door.
  testSync("follows the endpoint's own host and port", () => {
    expect(LocalSeedTarget.loginFor("http://localhost:4010/graphql"))->toEqual(
      "http://localhost:4010/__inmemory/login",
    )
    expect(LocalSeedTarget.loginFor("http://127.0.0.1:9999/graphql"))->toEqual(
      "http://127.0.0.1:9999/__inmemory/login",
    )
  })
})

describe("LocalSeedTarget.storePath", () => {
  let target = (store: LocalPlatformRegistry.store): LocalSeedTarget.t => {
    endpoint: "http://localhost:4000/graphql",
    loginEndpoint: "http://localhost:4000/__inmemory/login",
    origin: Running({
      app: "demo",
      port: 4000,
      pid: NodeProcess.pid,
      endpoint: "http://localhost:4000/graphql",
      loginEndpoint: "http://localhost:4000/__inmemory/login",
      store,
      startedAt: "2026-08-14T00:00:00.000Z",
    }),
  }

  testSync("hands back the file a SQLite platform opened", () => {
    expect(target(sqliteStore("/abs/.reventless/runner.db"))->LocalSeedTarget.storePath)->toEqual(
      Ok("/abs/.reventless/runner.db"),
    )
  })

  // Three different reasons there is no file, and a tool that collapsed them
  // would tell an in-memory platform to go and check its disk.
  testSync("explains each kind of store it cannot open, naming the platform", () => {
    let reason = t =>
      switch t->LocalSeedTarget.storePath {
      | Ok(_) => "unexpectedly resolved a path"
      | Error(message) => message
      }

    expect(target(memoryStore)->reason->String.includes("in memory"))->toEqual(true)
    expect(target(memoryStore)->reason->String.includes("localhost:4000"))->toEqual(true)
    expect(
      target({kind: "postgres", path: None})->reason->String.includes("off this machine"),
    )->toEqual(true)
    expect(
      {
        endpoint: "http://localhost:4000/graphql",
        loginEndpoint: "http://localhost:4000/__inmemory/login",
        origin: NoneRunning,
      }
      ->reason
      ->String.includes("no local platform is running"),
    )->toEqual(true)
  })
})
