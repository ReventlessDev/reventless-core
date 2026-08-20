// The deployed projection Lambdas assemble JSON-level QueryDb operations rather
// than going through `QueryDb_Operations.Make`, so the union `__typename` stamp
// that functor applies never ran on AWS. Every union member resolved to null and
// took its non-nullable parent with it — rows vanished from a view instead of
// erroring, on every read door, with nothing reporting it.
//
// The typed path was covered from the start; this side was not, which is the
// whole reason it shipped.

open JestGlobals

@schema
type geolocation =
  | Pending({requestedFor: string})
  | Located({lat: float, lng: float})

let geolocationSchema = Reventless.TaggedUnion.named(~name="Geolocation", geolocationSchema)

@schema
type rowState = {customerId: string, geolocation: geolocation}

// A recording stand-in for the storage the runtime would wrap.
let capture = (): (ReventlessCore.QueryDb_Adapter.operations, array<JSON.t>) => {
  let saved: array<JSON.t> = []
  let base: ReventlessCore.QueryDb_Adapter.operations = {
    load: _ => Promise.resolve(Ok([])),
    loadStream: _ => Stream.empty,
    save: (_id, state, _saveMode, _ttl) => {
      saved->Array.push(state)
      Promise.resolve(Ok())
    },
    saveBatch: items => {
      items->Array.forEach(((_, state, _)) => saved->Array.push(state))
      Promise.resolve(Ok())
    },
    count: (_, _, _) => Promise.resolve(Ok(0)),
    delete: (_, _) => Promise.resolve(Ok()),
    deleteBatch: _ => Promise.resolve(Ok()),
  }
  (base, saved)
}

let memberOf = (json: JSON.t) =>
  json
  ->JSON.Decode.object
  ->Option.flatMap(o => o->Dict.get("geolocation"))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(o => o->Dict.get("__typename"))
  ->Option.flatMap(JSON.Decode.string)

let row = (): JSON.t =>
  ({customerId: "c1", geolocation: Located({lat: 1.0, lng: 2.0})}: rowState)
  ->ReventlessCore.Message.encode(rowStateSchema)

describe("ProjectionEntryPoint_Ops.withUnionMemberTypes", () => {
  testPromise("stamps the member type on save", async () => {
    let (base, saved) = capture()
    let ops =
      base->ProjectionEntryPoint_Ops.withUnionMemberTypes(
        ~stateSchema=Some(rowStateSchema->S.castToUnknown),
      )
    let _ = await ops.save("c1", row(), ReventlessCore.QueryDb.Any, None)
    expect(saved->Array.get(0)->Option.flatMap(memberOf))->toEqual(Some("GeolocationLocated"))
  })

  // saveBatch is the path a multi-event projection takes, and it was missing the
  // stamp for the same reason save was.
  testPromise("stamps every row in a batch", async () => {
    let (base, saved) = capture()
    let ops =
      base->ProjectionEntryPoint_Ops.withUnionMemberTypes(
        ~stateSchema=Some(rowStateSchema->S.castToUnknown),
      )
    let _ = await ops.saveBatch([("c1", row(), None), ("c2", row(), None)])
    expect(saved->Array.map(memberOf))->toEqual([
      Some("GeolocationLocated"),
      Some("GeolocationLocated"),
    ])
  })

  // A spec module without a stateSchema leaves rows untouched rather than throwing.
  testPromise("passes rows through when the spec has no schema", async () => {
    let (base, saved) = capture()
    let ops = base->ProjectionEntryPoint_Ops.withUnionMemberTypes(~stateSchema=None)
    let _ = await ops.save("c1", row(), ReventlessCore.QueryDb.Any, None)
    expect(saved->Array.get(0)->Option.flatMap(memberOf))->toEqual(None)
  })
})
