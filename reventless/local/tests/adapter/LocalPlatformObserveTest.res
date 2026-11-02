// What the platform API and the platform MCP server offer a watching tool: the
// MCP resources for recent logs and all events answer and filter, and the API
// fields are refused to a caller without the admin group.

@@warning("-44")

open JestGlobals

module Logger = ReventlessCore.Logger

let _ = TestRunner.setup()
let opts: Pulumi.CustomResourceOptions.t = {}

let identity = (~groups): Reventless.Identity.t => {
  userId: "u-1",
  username: "u",
  groups,
  provider: InMemory,
}

let context = (~groups): JSON.t => Obj.magic({"identity": identity(~groups), "authenticated": true})

let admin = () => context(~groups=[Reventless.Role.adminGroup()])

let textOf = (r: McpSdk.readResourceResult): JSON.t =>
  (r.contents->Array.getUnsafe(0)).text->JSON.parseOrThrow

let field = (json: JSON.t, key: string): JSON.t =>
  json->JSON.Decode.object->Option.flatMap(d => d->Dict.get(key))->Option.getOr(JSON.Encode.null)

let strings = (items: JSON.t, key: string): array<string> =>
  items
  ->JSON.Decode.array
  ->Option.getOr([])
  ->Array.filterMap(i => i->field(key)->JSON.Decode.string)

describe("MCP resource platform/logs/recent", () => {
  afterEach(() => LocalLogFeed.resetForTests())

  testPromise("answers with the recent records, filtered by its query", async () => {
    LocalLogFeed.install(~env=Dict.make())
    Logger.emit(~level=Warn, ~comp="Projection", ~plugin="Ordering", "warned")
    Logger.emit(~level=Info, ~comp="Projection", ~plugin="Ordering", "informed")
    Logger.emit(~level=Error, ~comp="Projection", ~plugin="Catalog", "failed")
    let all = await LocalPlatformObserve.recentLogs("platform/logs/recent")
    expect(all->textOf->field("records")->strings("message"))->toEqual([
      "warned",
      "informed",
      "failed",
    ])
    let narrowed = await LocalPlatformObserve.recentLogs(
      "platform/logs/recent?plugins=Ordering&level=warn",
    )
    expect(narrowed->textOf->field("records")->strings("message"))->toEqual(["warned"])
    let last = await LocalPlatformObserve.recentLogs("platform/logs/recent?limit=1")
    expect(last->textOf->field("records")->strings("message"))->toEqual(["failed"])
  })
})

describe("MCP resource platform/events", () => {
  testPromise("answers with every log's events newest first, filtered by its query", async () => {
    BackendState.setMemory()
    LocalEventLogRead.resetForTests()
    module Bus = LocalBus.MakeSilent()
    module Dcb = LocalDcbEventLogStorage.Make(Bus)
    let catalog = await Dcb.make(
      ~name="CatalogDcbEventLog",
      ~indexes=[],
      ~partitionTag=Reventless.DcbTag.Simple({key: "productId"}),
      ~opts,
    ).operations->TestRunner.resolve
    LocalEventLogRead.notePlugin(~log="CatalogDcbEventLog", ~plugin="Catalog")
    let add = async (productId, correlationId) => {
      let _ = await catalog.append([
        {
          eventType: "Added",
          data: JSON.Encode.null,
          tags: [{key: "productId", value: productId}],
          meta: ReventlessCore.Message.generateMeta(~service="test", ~correlationId),
        },
      ])
    }
    await add("p-1", "flow-a")
    await add("p-2", "flow-b")
    await add("p-3", "flow-a")
    let all = await LocalPlatformObserve.events("platform/events")
    let tagValues = page =>
      page
      ->textOf
      ->field("edges")
      ->JSON.Decode.array
      ->Option.getOr([])
      ->Array.map(edge => edge->field("node")->field("tags")->strings("value")->Array.join(","))
    expect(all->tagValues)->toEqual(["p-3", "p-2", "p-1"])
    let flow = await LocalPlatformObserve.events("platform/events?correlationId=flow-a&first=1")
    expect(flow->tagValues)->toEqual(["p-3"])
    let cursor = flow->textOf->field("pageInfo")->field("endCursor")->JSON.Decode.string
    let next = await LocalPlatformObserve.events(
      `platform/events?correlationId=flow-a&first=1&after=${cursor->Option.getOr("")}`,
    )
    expect(next->tagValues)->toEqual(["p-1"])
    let none = await LocalPlatformObserve.events("platform/events?plugins=Ordering")
    expect(none->tagValues)->toEqual([])
  })
})

describe("the platform API's watching fields", () => {
  afterEach(() => Logger.clearLevels())

  let server = () => {
    let s = ReventlessGraphqlServer.GraphQL_ServerInstance.make(~label="Test")
    LocalPlatformObserve.registerGraphQL(s)
    s
  }

  testPromise("are refused to a caller without the admin group", async () => {
    let s = server()
    let refused = async (resolver: option<GraphqlYoga.resolverFn>) => {
      let run = resolver->Option.getOrThrow
      switch await run(JSON.Encode.null, JSON.Encode.null, context(~groups=["Customer"])) {
      | _ => false
      | exception _ => true
      }
    }
    expect(await refused(s.getQueryResolver(LocalPlatformObserve.eventLogField)))->toBe(true)
    expect(await refused(s.getQueryResolver(LocalPlatformObserve.viewChangesField)))->toBe(true)
    expect(await refused(s.getQueryResolver(LocalPlatformObserve.commandOutcomesField)))->toBe(true)
    expect(await refused(s.getQueryResolver(LocalPlatformObserve.logLevelsField)))->toBe(true)
    expect(await refused(s.getMutationResolver(LocalPlatformObserve.setLogLevelField)))->toBe(true)
    expect(await refused(s.getQueryResolver(LocalPlatformObserve.metricsField)))->toBe(true)
  })

  testPromise("set and list the log levels for an admin", async () => {
    let s = server()
    let set = s.getMutationResolver(LocalPlatformObserve.setLogLevelField)->Option.getOrThrow
    let args = JSON.parseOrThrow(`{"plugin":"Ordering","comp":"Projection","level":"DEBUG"}`)
    let answer = await set(JSON.Encode.null, args, admin())
    expect(answer->field("settings"))->toEqual(
      JSON.parseOrThrow(`[{"level":"DEBUG","plugin":"Ordering","comp":"Projection"}]`),
    )
    expect(Logger.minLevelFor(~plugin="Ordering", ~comp="Projection", ()))->toEqual(
      Some(Logger.Debug),
    )
    let cleared = await set(
      JSON.Encode.null,
      JSON.parseOrThrow(`{"plugin":"Ordering","comp":"Projection","level":null}`),
      admin(),
    )
    expect(cleared->field("settings"))->toEqual(JSON.parseOrThrow(`[]`))
  })

  testPromise("the event log answers an admin with a connection", async () => {
    BackendState.setMemory()
    LocalEventLogRead.resetForTests()
    let s = server()
    let read = s.getQueryResolver(LocalPlatformObserve.eventLogField)->Option.getOrThrow
    let answer = await read(JSON.Encode.null, JSON.parseOrThrow(`{"first":5}`), admin())
    expect(answer->field("edges"))->toEqual(JSON.Encode.array([]))
    expect(answer->field("pageInfo")->field("hasNextPage"))->toEqual(JSON.Encode.bool(false))
  })

  // Two flows: two changes in one, one in the other.
  let keepChanges = () => {
    let change = (~view, ~key, ~flow, msgId): ReventlessCore.ViewChange.t => {
      view,
      key,
      kind: Changed,
      fields: ["status"],
      after: JSON.parseOrThrow(`{"status":"shipped"}`),
      sources: [{msgId, correlationId: flow}],
      correlationId: flow,
    }
    LocalViewChangeLog.record(change(~view="Orders", ~key="o-1", ~flow="k-1", "m-1"))
    LocalViewChangeLog.record(change(~view="Customers", ~key="c-1", ~flow="k-2", "m-2"))
    LocalViewChangeLog.record(change(~view="Customers", ~key="c-1", ~flow="k-1", "m-3"))
  }

  let readChanges = async (args: string) => {
    let s = server()
    let read = s.getQueryResolver(LocalPlatformObserve.viewChangesField)->Option.getOrThrow
    await read(JSON.Encode.null, JSON.parseOrThrow(args), admin())
  }

  let views = (answer: JSON.t) =>
    answer
    ->field("edges")
    ->JSON.Decode.array
    ->Option.getOr([])
    ->Array.map(e => e->field("node")->field("view")->JSON.Decode.string->Option.getOr(""))

  let readsBack = async () => {
    keepChanges()
    let flow = await readChanges(`{"filter":{"correlationId":"k-1"}}`)
    let byEvent = await readChanges(`{"filter":{"msgId":"m-2"}}`)
    let firstPage = await readChanges(`{"filter":{"correlationId":"k-1"},"first":1}`)
    let cursor = firstPage->field("pageInfo")->field("endCursor")->JSON.Decode.string
    let secondPage = await readChanges(
      `{"filter":{"correlationId":"k-1"},"first":1,"after":"${cursor->Option.getOr("")}"}`,
    )
    (
      views(flow),
      views(byEvent),
      views(firstPage),
      firstPage->field("pageInfo")->field("hasNextPage"),
      views(secondPage),
      secondPage->field("pageInfo")->field("hasNextPage"),
    )
  }

  let expected = (
    ["Customers", "Orders"],
    ["Customers"],
    ["Customers"],
    JSON.Encode.bool(true),
    ["Orders"],
    JSON.Encode.bool(false),
  )

  testPromise(
    "the view changes answer an admin by flow and event, newest first, in pages",
    async () => {
      BackendState.setMemory()
      LocalViewChangeLog.resetForTests()
      expect(await readsBack())->toEqual(expected)
      LocalViewChangeLog.resetForTests()
    },
  )

  testPromise("the view changes are kept in a SQLite store alike", async () => {
    let db = SqliteDriver.openDb(~path=":memory:")
    BackendState.setSqlite(~db, ~path=":memory:")
    LocalViewChangeLog.resetForTests()
    expect(await readsBack())->toEqual(expected)
    LocalViewChangeLog.resetForTests()
    BackendState.setMemory()
    SqliteDriver.close(db)
  })

  // Three commands: two in one flow, one rejected.
  let keepOutcomes = () => {
    let report = (
      ~flow,
      ~outcome,
      msgId,
    ): ReventlessCore.CommandTopic_Helpers.commandOutcomeReport => {
      component: "Order",
      reference: msgId,
      correlationId: flow,
      outcome,
    }
    let accepted = ReventlessCore.CommandTopic_Helpers.OutcomeAccepted({
      entityId: Some("o-1"),
      eventCount: 1,
    })
    LocalCommandOutcomeLog.record(report(~flow="k-1", ~outcome=accepted, "c-1"))
    LocalCommandOutcomeLog.record(report(~flow="k-2", ~outcome=accepted, "c-2"))
    LocalCommandOutcomeLog.record(
      report(
        ~flow="k-1",
        ~outcome=OutcomeRejected({
          errorCode: "AlreadyShipped",
          errorDetail: "",
          cause: ReventlessCore.CommandTopic_Helpers.DomainRejection,
        }),
        "c-3",
      ),
    )
  }

  let outcomesRead = async () => {
    keepOutcomes()
    let s = server()
    let read = s.getQueryResolver(LocalPlatformObserve.commandOutcomesField)->Option.getOrThrow
    let ask = async args => {
      let answer = await read(JSON.Encode.null, JSON.parseOrThrow(args), admin())
      answer
      ->field("edges")
      ->JSON.Decode.array
      ->Option.getOr([])
      ->Array.map(e => {
        let node = e->field("node")
        (
          node->field("msgId")->JSON.Decode.string->Option.getOr(""),
          node->field("outcome")->JSON.Decode.string->Option.getOr(""),
        )
      })
    }
    (await ask(`{"filter":{"correlationId":"k-1"}}`), await ask(`{"filter":{"msgId":"c-2"}}`))
  }

  let outcomesExpected = ([("c-3", "rejected"), ("c-1", "accepted")], [("c-2", "accepted")])

  testPromise(
    "the command outcomes answer an admin by flow and by command, newest first",
    async () => {
      BackendState.setMemory()
      LocalCommandOutcomeLog.resetForTests()
      expect(await outcomesRead())->toEqual(outcomesExpected)
      LocalCommandOutcomeLog.resetForTests()
    },
  )

  testPromise("the command outcomes are kept in a SQLite store alike", async () => {
    let db = SqliteDriver.openDb(~path=":memory:")
    BackendState.setSqlite(~db, ~path=":memory:")
    LocalCommandOutcomeLog.resetForTests()
    expect(await outcomesRead())->toEqual(outcomesExpected)
    LocalCommandOutcomeLog.resetForTests()
    BackendState.setMemory()
    SqliteDriver.close(db)
  })

  testPromise("the metrics answer an admin with the counts, narrowed by plugin", async () => {
    let counts = LocalMetrics.counts
    ReventlessCore.Metrics.Counts.clear(counts)
    let sample = (~metric, ~plugin, ~value=1): ReventlessCore.Metrics.sample => {
      metric,
      slice: "PlaceOrder",
      plugin,
      value,
      unit: "Count",
      at: Date.now(),
    }
    counts->ReventlessCore.Metrics.Counts.add(sample(~metric="AppendRetry", ~plugin="Ordering"))
    counts->ReventlessCore.Metrics.Counts.add(sample(~metric="AppendRetry", ~plugin="Ordering"))
    counts->ReventlessCore.Metrics.Counts.add(sample(~metric="AppendRetry", ~plugin="Catalog"))
    let s = server()
    let read = s.getQueryResolver(LocalPlatformObserve.metricsField)->Option.getOrThrow
    let answer = await read(
      JSON.Encode.null,
      JSON.parseOrThrow(`{"plugins":["Ordering"]}`),
      admin(),
    )
    let rows = answer->JSON.Decode.array->Option.getOr([])
    expect(rows->Array.length)->toBe(1)
    let row = rows->Array.getUnsafe(0)
    expect(row->field("plugin"))->toEqual(JSON.Encode.string("Ordering"))
    expect(row->field("count"))->toEqual(JSON.Encode.int(2))
    ReventlessCore.Metrics.Counts.clear(counts)
  })

  testSync("the SDL builds into a schema", () => {
    let s = server()
    let sdl = s.buildSdl()
    expect(sdl->String.includes("Platform_EventLog(filter: Platform_EventLogFilter"))->toBe(true)
    let _ = GraphqlYoga.createSchema({"typeDefs": sdl, "resolvers": Dict.make()})
  })
})
