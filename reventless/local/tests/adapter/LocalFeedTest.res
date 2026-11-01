// The feeds a watching tool reads: a listener that stops reading costs the
// platform a bounded amount and is told what it missed; a filter line narrows
// what it is sent; the log feed starts with the recent records.

@@warning("-44")

open JestGlobals

module Logger = ReventlessCore.Logger

let sleep = (ms: int): promise<unit> =>
  Promise.make((resolve, _) => {
    let _ = setTimeout(() => resolve(), ms)
  })

// Polls until `cond` holds, for at most `ms`.
let until = async (~ms=2000, cond: unit => bool): bool => {
  let waited = ref(0)
  while !cond() && waited.contents < ms {
    await sleep(5)
    waited := waited.contents + 5
  }
  cond()
}

let bind = (feed: LocalFeed.t): promise<int> =>
  Promise.make((resolve, _) => feed->LocalFeed.start(~setting=Ephemeral, ~onBound=resolve, ()))

type client = {socket: NodeNet.socket, mutable received: string}

let connect = (port: int): promise<client> =>
  Promise.make((resolve, _) => {
    let c = ref(None)
    let socket = NodeNet.connect(port, "127.0.0.1", () =>
      c.contents->Option.forEach(client => resolve(client))
    )
    socket->NodeNet.setEncoding("utf8")
    socket->NodeNet.onSocketError(_ => ())
    let client = {socket, received: ""}
    socket->NodeNet.onSocketData(chunk => client.received = client.received ++ chunk)
    c := Some(client)
  })

let lines = (c: client): array<string> => c.received->String.split("\n")->Array.filter(l => l != "")

let skippedCounts = (c: client): array<int> =>
  c
  ->lines
  ->Array.filterMap(l =>
    switch l->JSON.parseOrThrow->JSON.Decode.object {
    | Some(d) if d->Dict.get("kind") == Some(JSON.String("skipped")) =>
      d->Dict.get("count")->Option.flatMap(JSON.Decode.float)->Option.map(Float.toInt)
    | _ => None
    | exception _ => None
    }
  )

describe("LocalFeed: a listener that never reads", () => {
  test(
    "costs a bounded amount, and is told how many lines it missed when it reads again",
    async () => {
      let maxBytes = 64 * 1024
      let feed = LocalFeed.make(
        ~name="TestFeed",
        ~honours=[],
        ~maxLines=200,
        ~maxBytes,
        ~filterWaitMs=10,
        (),
      )
      let port = await bind(feed)
      let client = await connect(port)
      expect(await until(() => feed->LocalFeed.hasReaders))->toBe(true)
      client.socket->NodeNet.pause

      // 20,000 lines of about 1 KB: twenty megabytes the listener does not read.
      let pad = String.repeat("x", 1000)
      let total = 20_000
      let held = ref(0)
      for i in 1 to total {
        feed->LocalFeed.broadcast(`{"n":${i->Int.toString},"pad":"${pad}"}`)
        held := Math.Int.max(held.contents, feed->LocalFeed.heldBytes)
      }
      // What the platform holds for it never exceeds the queue's bound plus what
      // one socket buffers before it reports backpressure.
      expect(feed->LocalFeed.queuedBytes <= maxBytes)->toBe(true)
      expect(held.contents < maxBytes + 4 * 1024 * 1024)->toBe(true)

      client.socket->NodeNet.resume
      let last = `{"n":${total->Int.toString},`
      expect(await until(~ms=5000, () => client.received->String.includes(last)))->toBe(true)
      let skipped = skippedCounts(client)->Array.reduce(0, (a, b) => a + b)
      expect(skipped > 0)->toBe(true)
      // Every line is either received or counted as skipped.
      let received = lines(client)->Array.filter(l => l->String.startsWith(`{"n":`))->Array.length
      expect(received + skipped)->toBe(total)
      NodeNet.destroySocket(client.socket)
      await feed->LocalFeed.stopForTests
    },
  )
})

describe("LocalFeed: the filter line", () => {
  testSync("is read leniently and ignores what it does not know", () => {
    expect(
      LocalFeed.parseFilter(`{"plugins":["Ordering"],"level":"WARN","eventTypes":["Placed"],"x":1}`),
    )->toEqual(Some({LocalFeed.plugins: ["Ordering"], level: Warn, eventTypes: ["Placed"]}))
    expect(LocalFeed.parseFilter("not json"))->toEqual(None)
  })

  testSync("narrows only by the fields the feed honours", () => {
    let filter: LocalFeed.filter = {plugins: ["Ordering"], level: Warn}
    let warnOrdering: LocalFeed.facets = {plugin: "Ordering", level: Warn}
    let infoOrdering: LocalFeed.facets = {plugin: "Ordering", level: Info}
    let catalog: LocalFeed.facets = {plugin: "Catalog", level: Error}
    let logs: array<LocalFeed.filterField> = [Plugins, Level]
    expect(LocalFeed.matches(~honours=logs, filter, warnOrdering))->toBe(true)
    expect(LocalFeed.matches(~honours=logs, filter, infoOrdering))->toBe(false)
    expect(LocalFeed.matches(~honours=logs, filter, catalog))->toBe(false)
    // An event has no level; the tap ignores the field.
    expect(LocalFeed.matches(~honours=[Plugins], filter, {plugin: "Ordering"}))->toBe(true)
  })

  test("narrows the event tap and the log feed alike", async () => {
    LocalEventTap.resetForTests()
    LocalLogFeed.resetForTests()
    LocalLogFeed.install(~env=Dict.make())
    // Logged before anyone connects: sent first, filtered, by the log feed.
    Logger.emit(~level=Warn, ~comp="Projection", ~plugin="Ordering", "before connect")
    Logger.emit(~level=Info, ~comp="Projection", ~plugin="Ordering", "before connect, quiet")

    let tapPort = await Promise.make(
      (resolve, _) => LocalEventTap.start(~env=Dict.make(), ~onBound=resolve, ()),
    )
    let logPort = await Promise.make(
      (resolve, _) => LocalLogFeed.start(~env=Dict.make(), ~onBound=resolve, ()),
    )
    let tap = await connect(tapPort)
    let logFeed = await connect(logPort)
    let filterLine = `{"plugins":["Ordering"],"level":"warn","eventTypes":["Placed"],"correlationId":"c-1"}\n`
    let _ = tap.socket->NodeNet.write(filterLine)
    let _ = logFeed.socket->NodeNet.write(filterLine)
    expect(await until(() => LocalEventTap.hasReaders() && LocalLogFeed.hasReaders()))->toBe(true)

    let event = (~plugin, ~eventType, ~correlationId, name) =>
      LocalEventTap.publish({
        line: `@@RVLESS_EVT@@ {"name":"${name}"}`,
        facets: {plugin, eventType, correlationId},
      })
    event(~plugin="Ordering", ~eventType="Placed", ~correlationId="c-1", "match")
    event(~plugin="Catalog", ~eventType="Placed", ~correlationId="c-1", "other plugin")
    event(~plugin="Ordering", ~eventType="Shipped", ~correlationId="c-1", "other type")
    event(~plugin="Ordering", ~eventType="Placed", ~correlationId="c-2", "other flow")

    let annotations = Dict.fromArray([("correlationId", "c-1")])
    Logger.emit(~level=Error, ~comp="Projection", ~plugin="Ordering", ~annotations, "live match")
    Logger.emit(~level=Info, ~comp="Projection", ~plugin="Ordering", ~annotations, "too quiet")
    Logger.emit(~level=Error, ~comp="Projection", ~plugin="Catalog", ~annotations, "other plugin")

    expect(await until(() => logFeed.received->String.includes("live match")))->toBe(true)
    expect(await until(() => tap.received->String.includes("match")))->toBe(true)
    await sleep(30)

    expect(tap->lines)->toEqual([`@@RVLESS_EVT@@ {"name":"match"}`])
    let messages =
      logFeed
      ->lines
      ->Array.filterMap(
        l =>
          l
          ->JSON.parseOrThrow
          ->JSON.Decode.object
          ->Option.flatMap(d => d->Dict.get("message"))
          ->Option.flatMap(JSON.Decode.string),
      )
    // The backlog line has no correlation id, so the filter's flow leaves it out.
    expect(messages)->toEqual(["live match"])

    NodeNet.destroySocket(tap.socket)
    NodeNet.destroySocket(logFeed.socket)
    await LocalEventTap.stopForTests()
    await LocalLogFeed.stopForTests()
    LocalLogFeed.resetForTests()
  })

  test("a listener that sends no filter gets everything, the recent records first", async () => {
    LocalLogFeed.resetForTests()
    LocalLogFeed.install(~env=Dict.make())
    Logger.emit(~level=Debug, ~comp="Projection", "earlier")
    let logPort = await Promise.make(
      (resolve, _) => LocalLogFeed.start(~env=Dict.make(), ~onBound=resolve, ()),
    )
    let client = await connect(logPort)
    expect(await until(() => LocalLogFeed.hasReaders()))->toBe(true)
    Logger.emit(~level=Debug, ~comp="Projection", "later")
    expect(await until(() => client.received->String.includes("later")))->toBe(true)
    let messages =
      client
      ->lines
      ->Array.filterMap(
        l =>
          l
          ->JSON.parseOrThrow
          ->JSON.Decode.object
          ->Option.flatMap(d => d->Dict.get("message"))
          ->Option.flatMap(JSON.Decode.string),
      )
    // Only this test's own lines: the platform's may be logged too.
    expect(messages->Array.filter(m => m == "earlier" || m == "later"))->toEqual([
      "earlier",
      "later",
    ])
    NodeNet.destroySocket(client.socket)
    await LocalLogFeed.stopForTests()
    LocalLogFeed.resetForTests()
  })
})

type consoleObj = {mutable log: string => unit}
@val external console: consoleObj = "console"

describe("LocalLogFeed: the rings", () => {
  afterEach(() => {
    LocalLogFeed.resetForTests()
    NodeProcess.env->Dict.set("REVENTLESS_LOG_FORMAT", "text")
    Reventless.AnsiStyle.reload()
  })

  testSync("a record in the ring equals the JSON line's fields", () => {
    LocalLogFeed.install(~env=Dict.make())
    NodeProcess.env->Dict.set("REVENTLESS_LOG_FORMAT", "json")
    Reventless.AnsiStyle.reload()
    let printed = []
    let original = console.log
    console.log = s => printed->Array.push(s)
    Logger.emit(
      ~level=Warn,
      ~comp="Aggregate(Order)",
      ~plugin="Ordering",
      ~annotations=Dict.fromArray([("correlationId", "c-9")]),
      ~detail=Dict.fromArray([("orderId", JSON.Encode.string("o-1"))])->JSON.Encode.object,
      "refused",
    )
    console.log = original
    // Only this test's own line: the platform's may be logged too.
    let entry =
      LocalLogFeed.snapshot()->Array.find(e => e.record.message == "refused")->Option.getOrThrow
    let line = printed->Array.find(l => l->String.includes(`"refused"`))->Option.getOrThrow
    expect(entry.item.line)->toEqual(line)
    expect(entry.record->Logger.recordToJson)->toEqual(line->JSON.parseOrThrow)
  })

  testSync("detail is redacted in the ring", () => {
    LocalLogFeed.install(~env=Dict.make())
    Logger.emit(
      ~level=Info,
      ~comp="Projection",
      ~detail=Dict.fromArray([
        ("name", Dict.fromArray([("$pii", JSON.Encode.string("Ada Secret"))])->JSON.Encode.object),
      ])->JSON.Encode.object,
      "joined",
    )
    let line = (LocalLogFeed.snapshot()->Array.getUnsafe(0)).item.line
    expect(line->String.includes("joined"))->toBe(true)
    expect(line->String.includes("Ada Secret"))->toBe(false)
  })

  testSync("the count bound holds, and warnings outlive it in their own ring", () => {
    LocalLogFeed.install(
      ~env=Dict.fromArray([(LocalLogFeed.ringEnvVar, "3"), (LocalLogFeed.problemRingEnvVar, "2")]),
    )
    Logger.emit(~level=Warn, ~comp="C", "warn 1")
    Logger.emit(~level=Error, ~comp="C", "error 2")
    Logger.emit(~level=Warn, ~comp="C", "warn 3")
    for i in 1 to 5 {
      Logger.emit(~level=Info, ~comp="C", `info ${i->Int.toString}`)
    }
    expect(LocalLogFeed.recent->LocalLogFeed.toArray->Array.map(e => e.record.message))->toEqual([
      "info 3",
      "info 4",
      "info 5",
    ])
    expect(LocalLogFeed.snapshot()->Array.map(e => e.record.message))->toEqual([
      "error 2",
      "warn 3",
      "info 3",
      "info 4",
      "info 5",
    ])
  })

  testSync("the byte bound holds", () => {
    LocalLogFeed.install(~env=Dict.fromArray([(LocalLogFeed.ringEnvVar, "1000,600")]))
    for i in 1 to 50 {
      Logger.emit(~level=Info, ~comp="C", `line ${i->Int.toString}`)
    }
    let kept = LocalLogFeed.recent->LocalLogFeed.toArray
    expect(LocalLogFeed.recent->LocalLogFeed.ringBytes <= 600)->toBe(true)
    expect(kept->Array.length > 0 && kept->Array.length < 50)->toBe(true)
    expect((kept->Array.at(-1)->Option.getOrThrow).record.message)->toEqual("line 50")
  })

  testSync("recentRecords filters like the feed and keeps the most recent", () => {
    LocalLogFeed.install(~env=Dict.make())
    Logger.emit(~level=Warn, ~comp="A", ~plugin="Ordering", "w1")
    Logger.emit(~level=Info, ~comp="A", ~plugin="Ordering", "i1")
    Logger.emit(~level=Error, ~comp="B", ~plugin="Ordering", "e1")
    Logger.emit(~level=Error, ~comp="A", ~plugin="Catalog", "e2")
    let messages = (~filter, ~limit=?) =>
      LocalLogFeed.recentRecords(~filter, ~limit?)->Array.map(r => r.message)
    expect(messages(~filter={plugins: ["Ordering"], level: Warn}))->toEqual(["w1", "e1"])
    expect(messages(~filter={components: ["A"]}, ~limit=2))->toEqual(["i1", "e2"])
  })
})
