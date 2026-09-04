// A reset used to unlink a served store at construction and only discover at the
// bind, ~1200 lines later, that it had lost the race.

@@warning("-44")

open JestGlobals

let tempRoot = (): string =>
  NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "reventless-start-"]))

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

let withoutBypass = (f: unit => unit) => {
  let previous = NodeProcess.env->Dict.get(LocalPlatformStart.bypassEnv)
  NodeProcess.env->Dict.delete(LocalPlatformStart.bypassEnv)
  let restore = () =>
    switch previous {
    | Some(v) => NodeProcess.env->Dict.set(LocalPlatformStart.bypassEnv, v)
    | None => ()
    }
  try {
    f()
    restore()
  } catch {
  | e =>
    restore()
    throw(e)
  }
}

describe("LocalPlatformStart.guardReset", () => {
  // The exact sequence that lost data.
  testSync("refuses a reset of a store a live platform opened, naming it", () => {
    let cwd = tempRoot()
    let store = NodePath.join([cwd, ".reventless", "local.db"])
    let _ = writeAt(~cwd, ~port=4000, ~store=sqliteStore(store))

    switch LocalPlatformStart.guardReset(~path=store, ~cwd, ()) {
    | () => fail("expected the reset to be refused")
    | exception JsExn(e) =>
      let message = e->JsExn.message->Option.getOr("")
      expect(message->String.includes(":4000"))->toEqual(true)
      expect(message->String.includes(NodeProcess.pid->Int.toString))->toEqual(true)
    }
  })

  // Entry paths are absolute; the configured one is what an operator typed.
  testSync("matches a relative configured path against the absolute registered one", () => {
    let cwd = tempRoot()
    let absolute = NodePath.join([NodeProcess.cwd(), ".reventless", "guard-probe.db"])
    let _ = writeAt(~cwd, ~port=4000, ~store=sqliteStore(absolute))

    expect(
      LocalPlatformStart.servedBy(~path="./.reventless/guard-probe.db", ~cwd, ())->Option.isSome,
    )->toEqual(true)
  })

  testSync("lets a reset through when nothing is serving that file", () => {
    let cwd = tempRoot()
    let _ = writeAt(~cwd, ~port=4000, ~store=sqliteStore(NodePath.join([cwd, "other.db"])))

    expect(LocalPlatformStart.servedBy(~path=NodePath.join([cwd, "local.db"]), ~cwd, ()))->toEqual(
      None,
    )
    LocalPlatformStart.guardReset(~path=NodePath.join([cwd, "local.db"]), ~cwd, ())
  })

  // A `kill -9` leaves the entry behind; a guard that trusted it would never pass.
  testSync("lets a reset through when the platform holding the store is gone", () => {
    let cwd = tempRoot()
    let store = NodePath.join([cwd, "local.db"])
    let _ = writeAt(~cwd, ~port=4000, ~store=sqliteStore(store), ~pid=deadPid)

    LocalPlatformStart.guardReset(~path=store, ~cwd, ())
  })

  // An in-memory platform names no path, so it can never hold a store file.
  testSync("ignores a platform that keeps its store in memory", () => {
    let cwd = tempRoot()
    let _ = writeAt(~cwd, ~port=4010, ~store=memoryStore)

    LocalPlatformStart.guardReset(~path=NodePath.join([cwd, "local.db"]), ~cwd, ())
  })
})

describe("LocalPlatformStart.orAddressRunning", () => {
  // The addressing path exits 0, so running it first would report success for a
  // wipe that never happened.
  testSync("refuses a reset before it addresses the platform holding the store", () => {
    let cwd = tempRoot()
    let relative = "./.reventless/order-probe.db"
    let _ = writeAt(~cwd, ~port=4000, ~store=sqliteStore(NodePath.resolve([relative])))

    let previousBackend = NodeProcess.env->Dict.get("REVENTLESS_LOCAL_BACKEND")
    NodeProcess.env->Dict.set("REVENTLESS_LOCAL_BACKEND", `sqlite:${relative}?reset`)
    let outcome = switch LocalPlatformStart.orAddressRunning(~cwd, ()) {
    | () => "returned or exited"
    | exception JsExn(e) => e->JsExn.message->Option.getOr("")
    }
    switch previousBackend {
    | Some(v) => NodeProcess.env->Dict.set("REVENTLESS_LOCAL_BACKEND", v)
    | None => NodeProcess.env->Dict.delete("REVENTLESS_LOCAL_BACKEND")
    }

    expect(outcome->String.includes("refusing to reset"))->toEqual(true)
    expect(outcome->String.includes(":4000"))->toEqual(true)
  })
})

describe("LocalPlatformStart.decide", () => {
  testSync("starts where nothing is running", () =>
    withoutBypass(() =>
      expect(LocalPlatformStart.decide(~cwd=tempRoot(), ()))->toEqual(LocalPlatformStart.Start)
    )
  )

  testSync("addresses the one platform already serving this directory", () =>
    withoutBypass(() => {
      let cwd = tempRoot()
      let _ = writeAt(~cwd, ~port=4000, ~store=sqliteStore(NodePath.join([cwd, "local.db"])))

      switch LocalPlatformStart.decide(~cwd, ()) {
      | Start => fail("expected the running platform to be addressed")
      | AlreadyRunning(entries) =>
        expect(entries->Array.map(e => e.port))->toEqual([4000])
        let lines = LocalPlatformStart.report(entries)
        expect(lines->Array.length)->toEqual(2)
        expect(lines->Array.join("\n")->String.includes(":4000"))->toEqual(true)
      }
    })
  )

  // The state this is trying to make impossible: say so rather than pick one.
  testSync("names all of them when two are running", () =>
    withoutBypass(() => {
      let cwd = tempRoot()
      let _ = writeAt(~cwd, ~port=4000, ~store=sqliteStore(NodePath.join([cwd, "local.db"])))
      let _ = writeAt(~cwd, ~port=4010, ~store=memoryStore)

      switch LocalPlatformStart.decide(~cwd, ()) {
      | Start => fail("expected both running platforms to be reported")
      | AlreadyRunning(entries) =>
        let printed = LocalPlatformStart.report(entries)->Array.join("\n")
        expect(printed->String.includes(":4000"))->toEqual(true)
        expect(printed->String.includes(":4010"))->toEqual(true)
      }
    })
  )

  // The escape hatch the e2e suites and the VS Code runner already take.
  testSync("starts anyway when REVENTLESS_DOMAIN_PORT names a port", () => {
    let cwd = tempRoot()
    let _ = writeAt(~cwd, ~port=4000, ~store=sqliteStore(NodePath.join([cwd, "local.db"])))
    let previous = NodeProcess.env->Dict.get(LocalPlatformStart.bypassEnv)
    NodeProcess.env->Dict.set(LocalPlatformStart.bypassEnv, "4010")
    let decision = LocalPlatformStart.decide(~cwd, ())
    switch previous {
    | Some(v) => NodeProcess.env->Dict.set(LocalPlatformStart.bypassEnv, v)
    | None => NodeProcess.env->Dict.delete(LocalPlatformStart.bypassEnv)
    }
    expect(decision)->toEqual(LocalPlatformStart.Start)
  })
})
