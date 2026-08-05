// The local object store follows the active backend's durability: with a
// file-backed SQLite database the bytes land beside it on disk, so uploads and
// offloaded payloads survive the restart that their events survive; with Memory
// they stay in-process.

@@warning("-44")

open JestGlobals

let tempRoot = (): string =>
  NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "reventless-objectstore-"]))

let bytes = NodeBuffer.fromStringUtf8

describe("ObjectStoreStorage_FileSystem", () => {
  testSync("put then get round-trips the bytes and the content type", () => {
    let root = tempRoot()
    ObjectStoreStorage_FileSystem.put(
      ~root,
      ~key="uploads/abc/logo.svg",
      ~bytes=bytes("<svg/>"),
      ~contentType="image/svg+xml",
    )
    expect(
      ObjectStoreStorage_FileSystem.get(~root, ~key="uploads/abc/logo.svg")->Option.map(((
        got,
        contentType,
      )) => (got->NodeBuffer.toStringUtf8, contentType)),
    )->toEqual(Some(("<svg/>", "image/svg+xml")))
  })

  testSync("the key's slashes become directories under objects/", () => {
    let root = tempRoot()
    ObjectStoreStorage_FileSystem.put(
      ~root,
      ~key="uploads/abc/logo.svg",
      ~bytes=bytes("x"),
      ~contentType="image/svg+xml",
    )
    expect(NodeFs.existsSync(NodePath.join([root, "objects", "uploads", "abc", "logo.svg"])))->toEqual(
      true,
    )
  })

  testSync("get returns None for a missing key", () => {
    let root = tempRoot()
    expect(ObjectStoreStorage_FileSystem.get(~root, ~key="uploads/none/x.svg"))->toEqual(None)
  })

  testSync("get returns None for a key naming a directory rather than an object", () => {
    let root = tempRoot()
    ObjectStoreStorage_FileSystem.put(
      ~root,
      ~key="uploads/abc/logo.svg",
      ~bytes=bytes("x"),
      ~contentType="image/svg+xml",
    )
    expect(ObjectStoreStorage_FileSystem.get(~root, ~key="uploads/abc"))->toEqual(None)
  })

  testSync("delete removes the object, its content type, and the directory it emptied", () => {
    let root = tempRoot()
    ObjectStoreStorage_FileSystem.put(
      ~root,
      ~key="uploads/abc/logo.svg",
      ~bytes=bytes("x"),
      ~contentType="image/svg+xml",
    )
    ObjectStoreStorage_FileSystem.delete(~root, ~key="uploads/abc/logo.svg")
    expect(ObjectStoreStorage_FileSystem.get(~root, ~key="uploads/abc/logo.svg"))->toEqual(None)
    expect(NodeFs.existsSync(NodePath.join([root, "objects", "uploads", "abc"])))->toEqual(false)
    expect(NodeFs.existsSync(NodePath.join([root, "object-meta", "uploads", "abc"])))->toEqual(false)
  })

  testSync("delete of an absent key is a no-op", () => {
    let root = tempRoot()
    ObjectStoreStorage_FileSystem.delete(~root, ~key="uploads/abc/gone.svg")
    expect(ObjectStoreStorage_FileSystem.get(~root, ~key="uploads/abc/gone.svg"))->toEqual(None)
  })

  testSync("offload payloads round-trip in their own keyspace", () => {
    let root = tempRoot()
    ObjectStoreStorage_FileSystem.putOffload(~root, ~key="sha256/deadbeef", ~bytes=`{"a":1}`)
    expect(ObjectStoreStorage_FileSystem.getOffload(~root, ~key="sha256/deadbeef"))->toEqual(
      Some(`{"a":1}`),
    )
    // Not reachable as a served object — the two trees are separate.
    expect(ObjectStoreStorage_FileSystem.get(~root, ~key="sha256/deadbeef"))->toEqual(None)
  })

  testSync("a traversing key is refused rather than written outside the root", () => {
    let root = tempRoot()
    ObjectStoreStorage_FileSystem.put(
      ~root,
      ~key="uploads/../../escaped.svg",
      ~bytes=bytes("x"),
      ~contentType="image/svg+xml",
    )
    // `objects/uploads/../../escaped.svg` resolves to `<root>/escaped.svg`.
    expect(NodeFs.existsSync(NodePath.join([root, "escaped.svg"])))->toEqual(false)
    expect(ObjectStoreStorage_FileSystem.get(~root, ~key="uploads/../../escaped.svg"))->toEqual(None)
  })

  testSync("reset clears the store's trees and leaves the rest of the root alone", () => {
    let root = tempRoot()
    NodeFs.writeFileSync(NodePath.join([root, "local.db"]), "not a real database")
    ObjectStoreStorage_FileSystem.put(
      ~root,
      ~key="uploads/abc/logo.svg",
      ~bytes=bytes("x"),
      ~contentType="image/svg+xml",
    )
    ObjectStoreStorage_FileSystem.putOffload(~root, ~key="sha256/deadbeef", ~bytes="{}")

    ObjectStoreStorage_FileSystem.reset(~root)

    expect(ObjectStoreStorage_FileSystem.get(~root, ~key="uploads/abc/logo.svg"))->toEqual(None)
    expect(ObjectStoreStorage_FileSystem.getOffload(~root, ~key="sha256/deadbeef"))->toEqual(None)
    expect(NodeFs.existsSync(NodePath.join([root, "local.db"])))->toEqual(true)
  })
})

describe("LocalObjectStore backend dispatch", () => {
  // Restore the module-global backend so a later assertion in this file (and the
  // suite's own default) sees Memory rather than whichever db a test opened.
  afterEach(() => BackendState.setMemory())

  testSync("a file-backed SQLite backend puts the bytes on disk beside the database", () => {
    let root = tempRoot()
    let path = NodePath.join([root, "local.db"])
    BackendState.setSqlite(~db=SqliteDriver.openDb(~path), ~path)

    LocalObjectStore.put(~key="uploads/abc/logo.svg", ~bytes=bytes("x"), ~contentType="image/png")

    expect(NodeFs.existsSync(NodePath.join([root, "objects", "uploads", "abc", "logo.svg"])))->toEqual(
      true,
    )
    expect(LocalObjectStore.get(~key="uploads/abc/logo.svg")->Option.map(e => e.contentType))->toEqual(
      Some("image/png"),
    )
  })

  testSync("an object stored on disk outlives the process that stored it", () => {
    let root = tempRoot()
    let path = NodePath.join([root, "local.db"])

    // First "process": store, then drop every trace of it from memory.
    BackendState.setSqlite(~db=SqliteDriver.openDb(~path), ~path)
    LocalObjectStore.put(~key="uploads/abc/logo.svg", ~bytes=bytes("kept"), ~contentType="image/png")
    LocalObjectStore.putOffload(~key="sha256/cafe", ~bytes=`{"structure":true}`)
    BackendState.setMemory()
    ObjectStoreStorage_InMemory.reset()

    // Second "process": same database file, same directory.
    BackendState.setSqlite(~db=SqliteDriver.openDb(~path), ~path)
    expect(
      LocalObjectStore.get(~key="uploads/abc/logo.svg")->Option.map(e => e.contentType),
    )->toEqual(Some("image/png"))
    expect(LocalObjectStore.getOffload(~key="sha256/cafe"))->toEqual(Some(`{"structure":true}`))
  })

  testSync("a `:memory:` SQLite backend keeps objects in process, writing nothing", () => {
    BackendState.setSqlite(~db=SqliteDriver.openDb(~path=":memory:"), ~path=":memory:")
    expect(BackendState.getObjectStoreRoot())->toEqual(None)

    LocalObjectStore.put(~key="uploads/abc/logo.svg", ~bytes=bytes("x"), ~contentType="image/png")
    expect(LocalObjectStore.get(~key="uploads/abc/logo.svg")->Option.isSome)->toEqual(true)
  })

  testSync("the Memory backend keeps objects in process", () => {
    BackendState.setMemory()
    expect(BackendState.getObjectStoreRoot())->toEqual(None)

    LocalObjectStore.put(~key="uploads/abc/mem.svg", ~bytes=bytes("x"), ~contentType="image/png")
    expect(LocalObjectStore.get(~key="uploads/abc/mem.svg")->Option.isSome)->toEqual(true)
    LocalObjectStore.delete(~key="uploads/abc/mem.svg")
    expect(LocalObjectStore.get(~key="uploads/abc/mem.svg"))->toEqual(None)
  })

  testSync("servedKey refuses a path that would climb out of the store", () => {
    expect(LocalObjectStore.servedKey("/uploads/../../etc/passwd"))->toEqual(None)
    expect(LocalObjectStore.servedKey("/uploads/abc/logo.svg"))->toEqual(Some("uploads/abc/logo.svg"))
  })
})
