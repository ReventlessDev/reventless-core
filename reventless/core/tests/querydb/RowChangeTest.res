// A view row carries the change that last wrote it: the flow, the event and the time, stamped
// by the encoder from what the projection is applying, and passed over when the row is read.

open JestGlobals
open QueryDbFixtures

module Ops = QueryDb_Operations.Make(
  ItemQueryDbSpec,
  {
    let jsonOps = mockJsonOps
  },
)

let _ = beforeEach(() => reset())

let ops: QueryDb.operations<string, ItemQueryDbSpec.state> = {
  load: Ops.load,
  loadStream: Ops.loadStream,
  save: Ops.save,
  saveBatch: Ops.saveBatch,
  count: Ops.count,
  delete: Ops.delete,
  deleteBatch: Ops.deleteBatch,
}

let changeOf = (id: string): option<(option<string>, option<string>)> =>
  store.contents
  ->Dict.get(id)
  ->Option.flatMap(rows => rows->Array.get(0))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(d => d->Dict.get(RowChange.key))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.map(c => (
    c->Dict.get("flow")->Option.flatMap(JSON.Decode.string),
    c->Dict.get("msgId")->Option.flatMap(JSON.Decode.string),
  ))

let source = (~flow="flow-1", msgId): Projection.changeSource => {msgId, correlationId: flow}

describe("a row's last change", () => {
  testPromise("is the last of the events the projection applied", async () => {
    let _ = await Projection.handleAction(
      ~sources=[source("m-1"), source("m-2")],
      Create("a", ({name: "A", count: 1}: ItemQueryDbSpec.state)),
      ops,
      None,
    )
    expect(changeOf("a"))->toEqual(Some((Some("flow-1"), Some("m-2"))))
  })

  testPromise("is not written by a save outside a projection", async () => {
    let _ = await Ops.save("a", ({name: "A", count: 1}: ItemQueryDbSpec.state), Init, None)
    expect(changeOf("a"))->toEqual(None)
  })

  testPromise("is each row's own when a projection writes several at once", async () => {
    let _ = await Promise.all([
      Projection.handleAction(
        ~sources=[source(~flow="flow-a", "m-a")],
        Create("a", ({name: "A", count: 1}: ItemQueryDbSpec.state)),
        ops,
        None,
      ),
      Projection.handleAction(
        ~sources=[source(~flow="flow-b", "m-b")],
        Create("b", ({name: "B", count: 1}: ItemQueryDbSpec.state)),
        ops,
        None,
      ),
    ])
    expect((changeOf("a"), changeOf("b")))->toEqual((
      Some((Some("flow-a"), Some("m-a"))),
      Some((Some("flow-b"), Some("m-b"))),
    ))
  })

  testPromise("is passed over when the row is read back", async () => {
    let _ = await Projection.handleAction(
      ~sources=[source("m-1")],
      Create("a", ({name: "A", count: 1}: ItemQueryDbSpec.state)),
      ops,
      None,
    )
    let rows = await Ops.loadStream("a")->Stream.runCollect->Effect.runPromise
    expect(rows->Array.map(r => (r.name, r.count)))->toEqual([("A", 1)])
  })
})
