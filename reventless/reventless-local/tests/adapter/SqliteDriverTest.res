// Round-trip test for the SqliteDriver wrapper.
// Uses an in-memory database (`:memory:`) so no filesystem cleanup is needed.

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect

describe("SqliteDriver", () => {
  testPromise("open / exec / prepare / run / get / all / iterate / close round-trip", async () => {
    let db = SqliteDriver.openDb(~path=":memory:")
    db->SqliteDriver.exec("CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)")

    let insert = db->SqliteDriver.prepare("INSERT INTO t(id, v) VALUES(?, ?)")
    insert->SqliteDriver.run([JSON.Encode.int(1), JSON.Encode.string("hello")])
    insert->SqliteDriver.run([JSON.Encode.int(2), JSON.Encode.string("world")])

    let selectAll = db->SqliteDriver.prepare("SELECT id, v FROM t WHERE id > ? ORDER BY id")
    let rows = selectAll->SqliteDriver.all([JSON.Encode.int(0)])
    expect(rows->Array.length)->toBe(2)
    let firstRow = rows->Array.getUnsafe(0)
    expect(firstRow->Dict.get("v")->Option.getOr(JSON.Encode.null))->toEqual(
      JSON.Encode.string("hello"),
    )

    let getOne = selectAll->SqliteDriver.get([JSON.Encode.int(0)])
    expect(getOne->Option.isSome)->toBe(true)

    let countViaIterate = ref(0)
    let iter = selectAll->SqliteDriver.iterate([JSON.Encode.int(0)])
    let _ = iter->Iterator.forEach(_row => countViaIterate := countViaIterate.contents + 1)
    expect(countViaIterate.contents)->toBe(2)

    db->SqliteDriver.close
  })

  testPromise("transaction commits on success, rolls back on exception", async () => {
    let db = SqliteDriver.openDb(~path=":memory:")
    db->SqliteDriver.exec("CREATE TABLE t(id INTEGER PRIMARY KEY)")
    let insert = db->SqliteDriver.prepare("INSERT INTO t(id) VALUES(?)")
    let countAll = db->SqliteDriver.prepare("SELECT COUNT(*) AS c FROM t")

    db->SqliteDriver.transaction(() => {
      insert->SqliteDriver.run([JSON.Encode.int(1)])
      insert->SqliteDriver.run([JSON.Encode.int(2)])
    })

    let row = countAll->SqliteDriver.get([])->Option.getOrThrow
    expect(row->Dict.get("c")->Option.getOr(JSON.Encode.null))->toEqual(JSON.Encode.int(2))

    let didThrow = ref(false)
    try {
      db->SqliteDriver.transaction(() => {
        insert->SqliteDriver.run([JSON.Encode.int(3)])
        throw(Failure("boom"))
      })
    } catch {
    | Failure(_) => didThrow := true
    }
    expect(didThrow.contents)->toBe(true)

    let rowAfter = countAll->SqliteDriver.get([])->Option.getOrThrow
    expect(rowAfter->Dict.get("c")->Option.getOr(JSON.Encode.null))->toEqual(JSON.Encode.int(2))

    db->SqliteDriver.close
  })

  testPromise("Backend.fromEnv parses sqlite path and reset flag", async () => {
    let originalEnv =
      Backend.processEnv->Dict.get("REVENTLESS_LOCAL_BACKEND")

    Backend.processEnv->Dict.set("REVENTLESS_LOCAL_BACKEND", "sqlite:./local.db")
    let parsed = Backend.fromEnv()
    expect(parsed)->toEqual(Backend.Sqlite({path: "./local.db", resetOnStart: false}))

    Backend.processEnv->Dict.set("REVENTLESS_LOCAL_BACKEND", "sqlite:./local.db?reset")
    let parsedReset = Backend.fromEnv()
    expect(parsedReset)->toEqual(Backend.Sqlite({path: "./local.db", resetOnStart: true}))

    Backend.processEnv->Dict.set("REVENTLESS_LOCAL_BACKEND", "memory")
    let parsedMem = Backend.fromEnv()
    expect(parsedMem)->toEqual(Backend.Memory)

    switch originalEnv {
    | Some(v) => Backend.processEnv->Dict.set("REVENTLESS_LOCAL_BACKEND", v)
    | None => Backend.processEnv->Dict.delete("REVENTLESS_LOCAL_BACKEND")
    }
  })
})
