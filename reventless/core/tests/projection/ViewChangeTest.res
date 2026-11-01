// Which rows an event changed: each row a projection writes or removes is reported
// once, with the message ids of the events whose actions were applied to it, and
// the `view changed` log line names the fields that changed, never their values.

open JestGlobals

@schema
type row = {
  name: string,
  total: int,
  token: @s.matches(Reventless.Sensitive.string) string,
}

/** A store of one row per key, in memory. */
let makeOps = (): (dict<row>, QueryDb.operations<string, row>) => {
  let rows: dict<row> = Dict.make()
  let ops: QueryDb.operations<string, row> = {
    load: async id => Ok(rows->Dict.get(id)->Option.mapOr([], r => [r])),
    loadStream: id => rows->Dict.get(id)->Option.mapOr([], r => [r])->Stream.fromIterable,
    save: async (id, state, _, _) => {
      rows->Dict.set(id, state)
      Ok()
    },
    saveBatch: async batch => {
      batch->Array.forEach(((id, state, _)) => rows->Dict.set(id, state))
      Ok()
    },
    count: async (_, _, n) => Ok(n),
    delete: async (id, _) => {
      rows->Dict.delete(id)
      Ok()
    },
    deleteBatch: async ids => {
      ids->Array.forEach(((id, _)) => rows->Dict.delete(id))
      Ok()
    },
  }
  (rows, ops)
}

let reporterFor = view =>
  ViewChange.reporter(~comp=`ReadModel(${view})`, ~view, ~stateToJson=state =>
    state->Reventless.Util_Sury.toJson(rowSchema)
  )

let source = (msgId): Projection.changeSource => {
  msgId,
  correlationId: "flow-1",
  entityId: "order-1",
  entityType: "Order",
}

let heard: ref<array<ViewChange.t>> = ref([])
let removeListener = ref(() => ())

let msgIdsOf = (c: ViewChange.t) => c.sources->Array.map(s => s.msgId)

describe("ViewChange", () => {
  beforeEach(() => {
    heard := []
    removeListener := ViewChange.register(c => heard := heard.contents->Array.concat([c]))
  })
  afterEach(() => removeListener.contents())

  testPromise(
    "one event changing two rows in two views gives two changes with its id",
    async () => {
      let (_, totals) = makeOps()
      let (seeded, names) = makeOps()
      seeded->Dict.set("b", {name: "B", total: 1, token: "t"})
      let sources = [source("m-1")]

      let _ = await Projection.handleAction(
        ~sources,
        ~onChange=reporterFor("Totals"),
        Create("a", {name: "A", total: 1, token: "t"}),
        totals,
        None,
      )
      let _ = await Projection.handleAction(
        ~sources,
        ~onChange=reporterFor("Names"),
        Update("b", r => {...r, total: r.total + 1}),
        names,
        None,
      )

      expect(
        heard.contents->Array.map(c => (c.view, c.key, ViewChange.kindLabel(c.kind), msgIdsOf(c))),
      )->toEqual([("Totals", "a", "created", ["m-1"]), ("Names", "b", "changed", ["m-1"])])
      expect((heard.contents->Array.getUnsafe(1)).fields)->toEqual(["total"])
      expect((heard.contents->Array.getUnsafe(0)).correlationId)->toEqual(Some("flow-1"))
      expect((heard.contents->Array.getUnsafe(0)).sources->Array.map(s => s.entityId))->toEqual([
        Some("order-1"),
      ])
    },
  )

  testPromise("a merged update keeps the ids of both events", async () => {
    let (seeded, ops) = makeOps()
    seeded->Dict.set("a", {name: "A", total: 0, token: "t"})

    await Projection.handleSourcedActions(
      ~onChange=reporterFor("Totals"),
      [
        {action: Update("a", r => {...r, total: r.total + 1}), sources: [source("m-1")]},
        {action: Update("a", r => {...r, total: r.total + 2}), sources: [source("m-2")]},
      ],
      ops,
      None,
    )

    expect(heard.contents->Array.map(msgIdsOf))->toEqual([["m-1", "m-2"]])
    expect((seeded->Dict.getUnsafe("a")).total)->toBe(3)
  })

  testPromise("a removal and a write that changed nothing", async () => {
    let (seeded, ops) = makeOps()
    seeded->Dict.set("a", {name: "A", total: 0, token: "t"})
    let sources = [source("m-1")]

    let _ = await Projection.handleAction(
      ~sources,
      ~onChange=reporterFor("Totals"),
      Update("a", r => {...r, name: "A"}),
      ops,
      None,
    )
    let _ = await Projection.handleAction(
      ~sources,
      ~onChange=reporterFor("Totals"),
      Delete("a"),
      ops,
      None,
    )

    expect(heard.contents->Array.map(c => ViewChange.kindLabel(c.kind)))->toEqual(["removed"])
  })

  testPromise("the log line names the changed fields and never their values", async () => {
    let lines = []
    let removeSink = Logger.addSink(r => lines->Array.push(r))
    let (seeded, ops) = makeOps()
    seeded->Dict.set("a", {name: "A", total: 0, token: "old-secret"})

    let _ = await Projection.handleAction(
      ~sources=[source("m-1")],
      ~onChange=reporterFor("Totals"),
      Update("a", r => {...r, total: 5, token: "new-secret"}),
      ops,
      None,
    )
    removeSink()

    let viewLines = lines->Array.filter(r => r.message == "view changed")
    expect(viewLines->Array.length)->toBe(1)
    let line = viewLines->Array.getUnsafe(0)
    let printed = line->Logger.recordToJson->JSON.stringify
    expect(line.level)->toEqual(Logger.Info)
    expect(line.comp)->toEqual(Some("ReadModel(Totals)"))
    expect(line.annotations->Dict.get("correlationId"))->toEqual(Some("flow-1"))
    expect(printed->String.includes(`"fields":["total","token"]`))->toBe(true)
    expect(printed->String.includes(`"msgId":"m-1"`))->toBe(true)
    expect(printed->String.includes(`"entityType":"Order"`))->toBe(true)
    expect(printed->String.includes("secret"))->toBe(false)
    // The listener gets the values, for a reader that redacts them itself.
    expect(
      (heard.contents->Array.getUnsafe(0)).after
      ->Option.map(j => j->JSON.stringify)
      ->Option.mapOr(false, s => s->String.includes("new-secret")),
    )->toBe(true)
  })
})
