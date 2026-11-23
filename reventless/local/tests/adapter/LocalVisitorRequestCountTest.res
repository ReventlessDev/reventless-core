open JestGlobals

// The local counting of visitor requests: each request adds to its minute's row
// and its hour's, a refused one to `refused` too, and requests made at once are
// all counted.

module C = Reventless.VisitorRequestCount

/** A view in memory with the two calls the recorder makes. */
let view = () => {
  let rows: dict<JSON.t> = Dict.make()
  let ops: ReventlessCore.QueryDb_Adapter.operations = {
    load: async id => Ok(rows->Dict.get(id)->Option.mapOr([], r => [r])),
    loadStream: _ => Stream.empty,
    save: async (id, json, _, _) => {
      rows->Dict.set(id, json)
      Ok()
    },
    saveBatch: async _ => Ok(),
    count: async (_, _, _) => Ok(0),
    delete: async (_, _) => Ok(),
    deleteBatch: async _ => Ok(),
  }
  (rows, ops)
}

let settle = () =>
  Promise.make((resolve, _) => {
    let _ = setTimeout(() => resolve(), 20)
  })

describe("LocalVisitorRequestCount", () => {
  testPromise("counts each request in its minute and hour, and refused ones apart", async () => {
    let (rows, ops) = view()
    let record = LocalVisitorRequestCount.make(~ops=() => Some(ops))
    record(~kind=Door, ~admitted=true)
    record(~kind=Door, ~admitted=false)
    record(~kind=View, ~admitted=true)
    await settle()
    let now = Date.make()
    let row = (kind, seconds) =>
      rows
      ->Dict.get(C.idOf(~kind, ~seconds, ~start=C.startOf(~seconds, now)))
      ->Option.map(json => Reventless.Util_Sury.fromJson(json, C.rowSchema))
      ->Option.map(r => (r.requests, r.refused))
    let ever = kind =>
      rows
      ->Dict.get(C.everId(~kind))
      ->Option.map(json => Reventless.Util_Sury.fromJson(json, C.rowSchema))
      ->Option.map(r => (r.requests, r.refused))
    expect((row("door", 60), row("door", 3600), row("view", 60), ever("door")))->toEqual((
      Some((Some(2), Some(1))),
      Some((Some(2), Some(1))),
      Some((Some(1), Some(0))),
      Some((Some(2), Some(1))),
    ))
  })

  testPromise("counts nothing while there is no view", async () => {
    let (rows, _) = view()
    let record = LocalVisitorRequestCount.make(~ops=() => None)
    record(~kind=Door, ~admitted=true)
    await settle()
    expect(rows->Dict.keysToArray)->toEqual([])
  })
})
