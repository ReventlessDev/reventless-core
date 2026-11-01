// One read across every event log, newest first, on each backend: two plugins,
// aggregate and DCB logs. Pages join without a gap or a double while events are
// appended, every filter narrows, a correlation filter uses its index, and the
// tap's log and position are the read's.

@@warning("-44")

open JestGlobals

let _ = TestRunner.setup()
let opts: Pulumi.CustomResourceOptions.t = {}

@val external processEnv: dict<string> = "process.env"

// What the test appended, to compare the read with.
type appended = {
  log: string,
  plugin: string,
  msgId: string,
  eventType: string,
  entityId?: string,
  tags: array<Reventless.DcbTag.tag>,
  correlationId: string,
  causationId: string,
  user: string,
}

let ordersLog = "OrderAggrEventLog"
let customersLog = "CustomerAggrEventLog"
let catalogLog = "CatalogDcbEventLog"

type world = {
  appendOrder: (
    ~id: string,
    ~eventType: string,
    ~correlationId: string,
    ~user: string,
  ) => promise<unit>,
  appendCustomer: (~id: string, ~correlationId: string, ~user: string) => promise<unit>,
  appendProduct: (
    ~productId: string,
    ~eventType: string,
    ~correlationId: string,
    ~user: string,
  ) => promise<unit>,
  appended: array<appended>,
}

let resolveOrThrow = async (r: promise<result<'a, 'e>>) =>
  switch await r {
  | Ok(_) => ()
  | Error(_) => JsError.throwWithMessage("append failed")
  }

/** Storages through the platform's own dispatchers, so each backend registers
    its reader the way the platform does. */
let makeWorld = async (): world => {
  LocalEventLogRead.resetForTests()
  module Bus = LocalBus.MakeSilent()
  module Agg = LocalEventLogStorage.Make(Bus)
  module Dcb = LocalDcbEventLogStorage.Make(Bus)
  let orders = await Agg.make(~name=ordersLog, ~owner=None, ~opts).operations->TestRunner.resolve
  let customers = await Agg.make(
    ~name=customersLog,
    ~owner=None,
    ~opts,
  ).operations->TestRunner.resolve
  let catalog = await Dcb.make(
    ~name=catalogLog,
    ~indexes=[],
    ~partitionTag=Reventless.DcbTag.Simple({key: "productId"}),
    ~opts,
  ).operations->TestRunner.resolve
  LocalEventLogRead.notePlugin(~log=ordersLog, ~plugin="Ordering")
  LocalEventLogRead.notePlugin(~log=customersLog, ~plugin="Ordering")
  LocalEventLogRead.notePlugin(~log=catalogLog, ~plugin="Catalog")

  let appended = []
  let seqs = Dict.make()
  let flat = (~id, ~eventType, ~meta: Reventless.Message.meta) =>
    Dict.fromArray([
      ("id", JSON.Encode.string(id)),
      ("position", JSON.Encode.string("000000000")),
      ("event", JSON.Encode.string(eventType)),
      ("data", Dict.fromArray([("TAG", JSON.Encode.string(eventType))])->JSON.Encode.object),
      ("recordedAt", JSON.Encode.string(Date.make()->Date.toISOString)),
    ])
    ->Dict.toArray
    ->Array.concat(ReventlessCore.Message.decomposeMeta(meta))
    ->Dict.fromArray
    ->JSON.Encode.object
  let appendAggregate = async (
    ops: ReventlessCore.EventLog_Adapter.operations,
    ~log,
    ~plugin,
    ~id,
    ~eventType,
    ~correlationId,
    ~user,
  ) => {
    let meta = ReventlessCore.Message.generateMeta(
      ~service="test",
      ~user,
      ~correlationId,
      ~causationId=`cause-of-${correlationId}`,
    )
    let key = log ++ "/" ++ id
    let seq = seqs->Dict.get(key)->Option.getOr(0)
    await ops.append(seq, id, [flat(~id, ~eventType, ~meta)])->resolveOrThrow
    seqs->Dict.set(key, seq + 1)
    appended->Array.push({
      log,
      plugin,
      msgId: meta.msgId,
      eventType,
      entityId: id,
      tags: [],
      correlationId,
      causationId: `cause-of-${correlationId}`,
      user,
    })
  }
  {
    appendOrder: (~id, ~eventType, ~correlationId, ~user) =>
      appendAggregate(
        orders,
        ~log=ordersLog,
        ~plugin="Ordering",
        ~id,
        ~eventType,
        ~correlationId,
        ~user,
      ),
    appendCustomer: (~id, ~correlationId, ~user) =>
      appendAggregate(
        customers,
        ~log=customersLog,
        ~plugin="Ordering",
        ~id,
        ~eventType="Registered",
        ~correlationId,
        ~user,
      ),
    appendProduct: async (~productId, ~eventType, ~correlationId, ~user) => {
      let meta = ReventlessCore.Message.generateMeta(
        ~service="test",
        ~user,
        ~correlationId,
        ~causationId=`cause-of-${correlationId}`,
      )
      let tags: array<Reventless.DcbTag.tag> = [{key: "productId", value: productId}]
      await catalog.append([
        {
          eventType,
          data: Dict.fromArray([("TAG", JSON.Encode.string(eventType))])->JSON.Encode.object,
          tags,
          meta,
        },
      ])->resolveOrThrow
      appended->Array.push({
        log: catalogLog,
        plugin: "Catalog",
        msgId: meta.msgId,
        eventType,
        tags,
        correlationId,
        causationId: `cause-of-${correlationId}`,
        user,
      })
    },
    appended,
  }
}

let seed = async (w: world) =>
  for i in 1 to 12 {
    let correlationId = mod(i, 3) == 0 ? "flow-a" : "flow-b"
    let user = mod(i, 2) == 0 ? "u-even" : "u-odd"
    await w.appendOrder(
      ~id=`o-${mod(i, 3)->Int.toString}`,
      ~eventType=mod(i, 2) == 0 ? "Placed" : "Paid",
      ~correlationId,
      ~user,
    )
    await w.appendProduct(
      ~productId=`p-${mod(i, 2)->Int.toString}`,
      ~eventType=mod(i, 4) == 0 ? "Archived" : "Added",
      ~correlationId,
      ~user,
    )
    if mod(i, 4) == 1 {
      await w.appendCustomer(~id=`c-${i->Int.toString}`, ~correlationId, ~user)
    }
  }

let msgIdOf = (r: LocalEventLogRead.record) =>
  LocalEventLogRead.metaString(r.meta, "msgId")->Option.getOr("")

let readAll = async (~filter: LocalEventLogRead.filter, ~first: int): array<
  LocalEventLogRead.record,
> => {
  let out = []
  let after = ref(None)
  let more = ref(true)
  while more.contents {
    let page = await LocalEventLogRead.read(~filter, ~first, ~after=?after.contents)
    page.edges->Array.forEach(((r, _)) => out->Array.push(r))
    more := page.hasNextPage
    after := page.endCursor
  }
  out
}

let sorted = (ids: array<string>) => ids->Array.toSorted(String.compare)

let scenario = (~name: string, ~setup: unit => promise<unit>, ~teardown: unit => promise<unit>) =>
  describe(`LocalEventLogRead on ${name}`, () => {
    let run = async (body: unit => promise<unit>) => {
      await setup()
      let outcome = try {
        await body()
        Ok()
      } catch {
      | e => Error(e)
      }
      await teardown()
      switch outcome {
      | Ok() => ()
      | Error(e) => throw(e)
      }
    }

    test(
      "pages run newest first and join without a gap or a double while events are appended",
      () =>
        run(
          async () => {
            let w = await makeWorld()
            await seed(w)
            let total = w.appended->Array.length
            let everything = await readAll(~filter={}, ~first=1000)
            expect(everything->Array.length)->toBe(total)
            expect(everything->Array.map(msgIdOf)->sorted)->toEqual(
              w.appended->Array.map(a => a.msgId)->sorted,
            )
            // Newest first by the time each event was recorded.
            everything->Array.forEachWithIndex(
              (r, i) =>
                switch everything->Array.get(i + 1) {
                | Some(next) => expect(r.recordedAt >= next.recordedAt)->toBe(true)
                | None => ()
                },
            )
            expect(everything->Array.some(r => r.plugin == Some("Catalog")))->toBe(true)
            expect(everything->Array.some(r => r.plugin == Some("Ordering")))->toBe(true)

            // Paged by five, with events appended to every log after the first page.
            let first = await LocalEventLogRead.read(~filter={}, ~first=5)
            expect(first.hasNextPage)->toBe(true)
            await w.appendOrder(~id="o-new", ~eventType="Placed", ~correlationId="late", ~user="u")
            await w.appendProduct(
              ~productId="p-new",
              ~eventType="Added",
              ~correlationId="late",
              ~user="u",
            )
            await w.appendCustomer(~id="c-new", ~correlationId="late", ~user="u")
            let rest = []
            let after = ref(first.endCursor)
            let more = ref(true)
            while more.contents {
              let page = await LocalEventLogRead.read(~filter={}, ~first=5, ~after=?after.contents)
              page.edges->Array.forEach(((r, _)) => rest->Array.push(r))
              more := page.hasNextPage
              after := page.endCursor
            }
            let paged = first.edges->Array.map(((r, _)) => r)->Array.concat(rest)
            // The same events in the same order as one read before the appends.
            expect(paged->Array.map(msgIdOf))->toEqual(everything->Array.map(msgIdOf))

            // An edge's cursor continues right after it.
            let (_, thirdCursor) = first.edges->Array.getUnsafe(2)
            let fromThird = await LocalEventLogRead.read(~filter={}, ~first=2, ~after=thirdCursor)
            expect(fromThird.edges->Array.map(((r, _)) => msgIdOf(r)))->toEqual(
              everything->Array.slice(~start=3, ~end=5)->Array.map(msgIdOf),
            )

            // A new read sees the late events first.
            let fresh = await LocalEventLogRead.read(~filter={}, ~first=3)
            expect(
              fresh.edges->Array.every(
                ((r, _)) => LocalEventLogRead.metaString(r.meta, "correlationId") == Some("late"),
              ),
            )->toBe(true)
          },
        ),
    )

    test("every filter narrows", () =>
      run(
        async () => {
          let w = await makeWorld()
          await seed(w)
          let expectFilter = async (filter: LocalEventLogRead.filter, keep: appended => bool) => {
            let got = await readAll(~filter, ~first=4)
            let wanted = w.appended->Array.filter(keep)->Array.map(a => a.msgId)->sorted
            expect(wanted->Array.length > 0)->toBe(true)
            expect(wanted->Array.length < w.appended->Array.length)->toBe(true)
            expect(got->Array.map(msgIdOf)->sorted)->toEqual(wanted)
          }
          await expectFilter({plugins: ["Catalog"]}, a => a.plugin == "Catalog")
          await expectFilter({logs: [customersLog, catalogLog]}, a => a.log != ordersLog)
          await expectFilter(
            {eventTypes: ["Placed", "Archived"]},
            a => a.eventType == "Placed" || a.eventType == "Archived",
          )
          await expectFilter({entityId: "o-1"}, a => a.entityId == Some("o-1"))
          await expectFilter({entityId: "p-1"}, a => a.tags->Array.some(t => t.value == "p-1"))
          await expectFilter(
            {tagKey: "productId", tagValue: "p-0"},
            a => a.tags->Array.some(t => t.key == "productId" && t.value == "p-0"),
          )
          let one = w.appended->Array.getUnsafe(5)
          await expectFilter({msgId: one.msgId}, a => a.msgId == one.msgId)
          await expectFilter({correlationId: "flow-a"}, a => a.correlationId == "flow-a")
          await expectFilter(
            {causationId: "cause-of-flow-a"},
            a => a.causationId == "cause-of-flow-a",
          )
          await expectFilter({user: "u-even"}, a => a.user == "u-even")
          await expectFilter(
            {plugins: ["Ordering"], correlationId: "flow-b", user: "u-odd"},
            a => a.plugin == "Ordering" && a.correlationId == "flow-b" && a.user == "u-odd",
          )

          // Time: the newer half of a read, by its own recordedAt.
          let everything = await readAll(~filter={}, ~first=100)
          let middle = (everything->Array.getUnsafe(everything->Array.length / 2)).recordedAt
          let newer = await readAll(~filter={timeFrom: middle}, ~first=7)
          expect(newer->Array.map(msgIdOf)->sorted)->toEqual(
            everything->Array.filter(r => r.recordedAt >= middle)->Array.map(msgIdOf)->sorted,
          )
          let older = await readAll(~filter={timeTo: middle}, ~first=7)
          expect(older->Array.map(msgIdOf)->sorted)->toEqual(
            everything->Array.filter(r => r.recordedAt <= middle)->Array.map(msgIdOf)->sorted,
          )
        },
      )
    )

    test("each event's log and position, as noted for the tap, are the read's", () =>
      run(
        async () => {
          let w = await makeWorld()
          await w.appendOrder(~id="o-1", ~eventType="Placed", ~correlationId="tap", ~user="u")
          await w.appendProduct(
            ~productId="p-1",
            ~eventType="Added",
            ~correlationId="tap",
            ~user="u",
          )
          let read = await readAll(~filter={}, ~first=10)
          read->Array.forEach(
            r => {
              let noted = LocalEventLogRead.take(msgIdOf(r))
              expect(
                noted->Option.map(
                  ((log, position)) => (log, position->LocalEventLogRead.positionToString),
                ),
              )->toEqual(Some((r.log, r.position)))
            },
          )
        },
      )
    )
  })

scenario(~name="memory", ~setup=async () => BackendState.setMemory(), ~teardown=async () => ())

let sqliteDb: ref<option<SqliteDriver.t>> = ref(None)
scenario(
  ~name="SQLite",
  ~setup=async () => {
    let db = SqliteDriver.openDb(~path=":memory:")
    sqliteDb := Some(db)
    BackendState.setSqlite(~db, ~path=":memory:")
  },
  ~teardown=async () => {
    BackendState.setMemory()
    sqliteDb.contents->Option.forEach(SqliteDriver.close)
    sqliteDb := None
  },
)

switch processEnv->Dict.get("PG_URL") {
| None =>
  testSync("LocalEventLogRead on Postgres (skipped — set PG_URL to run)", () =>
    expect(true)->toBe(true)
  )
| Some(url) =>
  let pool = ReventlessPostgres.PgDriver.makePool({connectionString: url})
  scenario(
    ~name="Postgres",
    ~setup=async () => {
      await ReventlessPostgres.PgSchema.ensureSchema(pool)
      await ReventlessPostgres.PgSchema.truncateAll(pool)
      BackendState.setPostgres(~pool)
    },
    ~teardown=async () => BackendState.setMemory(),
  )
  describe("the correlation index on Postgres", () => {
    afterAll(() => {
      let _ = pool->ReventlessPostgres.PgDriver.endPool
    })
    test("a correlation filter's plan uses the index, on both tables", async () => {
      await ReventlessPostgres.PgSchema.ensureSchema(pool)
      let plan = async sql =>
        await pool->ReventlessPostgres.PgDriver.transaction(
          async client => {
            await client->ReventlessPostgres.PgDriver.execOn("SET LOCAL enable_seqscan = off")
            (await client->ReventlessPostgres.PgDriver.queryOn(sql, []))
            ->Array.map(
              row => row->Dict.valuesToArray->Array.map(v => JSON.stringify(v))->Array.join(" "),
            )
            ->Array.join("\n")
          },
        )
      let aggregate = await plan(
        "EXPLAIN SELECT global_seq FROM event_log WHERE log_name = 'L' AND (payload->>'correlationId') = 'c' ORDER BY global_seq DESC LIMIT 10",
      )
      expect(aggregate->String.includes("event_log_correlation"))->toBe(true)
      let dcb = await plan(
        "EXPLAIN SELECT position FROM dcb_event WHERE log_name = 'L' AND (meta->>'correlationId') = 'c' ORDER BY position DESC LIMIT 10",
      )
      expect(dcb->String.includes("dcb_event_correlation"))->toBe(true)
    })
  })
}

describe("the correlation index on SQLite", () => {
  let planOf = (db, (sql, params)) =>
    db
    ->SqliteDriver.prepare("EXPLAIN QUERY PLAN " ++ sql)
    ->SqliteDriver.all(params)
    ->Array.map(row =>
      row->Dict.get("detail")->Option.flatMap(JSON.Decode.string)->Option.getOr("")
    )
    ->Array.join("\n")

  testSync("a correlation filter's plan uses the index, on both tables", () => {
    let db = SqliteDriver.openDb(~path=":memory:")
    EventLogStorage_Sqlite.ensureSchema(db)
    DcbEventLogStorage_Sqlite.ensureSchema(db)
    let aggregate = planOf(
      db,
      EventLogStorage_Sqlite.readBackSql(
        ~name="L",
        ~bound=Some(Below(100.)),
        ~limit=10,
        ~correlationId=Some("c"),
      ),
    )
    expect(aggregate->String.includes("event_log_by_correlation"))->toBe(true)
    let dcb = planOf(
      db,
      DcbEventLogStorage_Sqlite.readBackSql(
        ~name="L",
        ~bound=Some(Below(100.)),
        ~limit=10,
        ~correlationId=Some("c"),
      ),
    )
    expect(dcb->String.includes("dcb_event_by_correlation"))->toBe(true)
    db->SqliteDriver.close
  })

  testSync("an existing store gains the indexes when it is opened", () => {
    let db = SqliteDriver.openDb(~path=":memory:")
    db->SqliteDriver.exec(
      "CREATE TABLE event_log (log_name TEXT NOT NULL, aggregate_id TEXT NOT NULL, seq_nr INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (log_name, aggregate_id, seq_nr))",
    )
    EventLogStorage_Sqlite.ensureSchema(db)
    let names =
      db
      ->SqliteDriver.prepare("SELECT name FROM sqlite_master WHERE type = 'index'")
      ->SqliteDriver.all([])
      ->Array.filterMap(row => row->Dict.get("name")->Option.flatMap(JSON.Decode.string))
    expect(names->Array.includes("event_log_by_correlation"))->toBe(true)
    db->SqliteDriver.close
  })
})

type consoleObj = {mutable log: string => unit}
@val external console: consoleObj = "console"

describe("the tap line", () => {
  testPromise("carries the event's log and position when its storage noted them", async () => {
    NodeProcess.env->Dict.set("REVENTLESS_EVENT_TAP", "ndjson")
    module Bus = LocalBus.MakeSilent()
    let meta = ReventlessCore.Message.generateMeta(~service="test")
    LocalEventLogRead.note(~log=ordersLog, ~msgId=meta.msgId, ~position=42.)
    let printed = []
    let original = console.log
    console.log = s => printed->Array.push(s)
    await Bus.publishEvent(
      "OrderAggrEventTopic",
      "Order",
      meta,
      JSON.parseOrThrow(`{"event":{"TAG":"Placed"}}`),
    )
    let other = ReventlessCore.Message.generateMeta(~service="test")
    await Bus.publishEvent("Lonely", "svc", other, JSON.Encode.null)
    console.log = original
    NodeProcess.env->Dict.delete("REVENTLESS_EVENT_TAP")
    let lines =
      printed
      ->Array.filter(l => l->String.startsWith("@@RVLESS_EVT@@ "))
      ->Array.map(
        l =>
          l
          ->String.slice(~start=15, ~end=l->String.length)
          ->JSON.parseOrThrow
          ->JSON.Decode.object
          ->Option.getOrThrow,
      )
    let field = (d, k) => d->Dict.get(k)->Option.flatMap(JSON.Decode.string)
    let first = lines->Array.getUnsafe(0)
    expect(field(first, "log"))->toEqual(Some(ordersLog))
    expect(field(first, "position"))->toEqual(Some("42"))
    // Every field the line had before is still there.
    ["event", "seq", "topic", "service", "payload", "ts"]->Array.forEach(
      k => expect(first->Dict.get(k)->Option.isSome)->toBe(true),
    )
    // An event published without a log has neither.
    let second = lines->Array.getUnsafe(1)
    expect(second->Dict.get("log"))->toEqual(None)
    expect(second->Dict.get("position"))->toEqual(None)
  })
})
