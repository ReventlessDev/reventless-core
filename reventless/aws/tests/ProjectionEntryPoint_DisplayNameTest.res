// The `@displayName` overlay reached the typed paths — the local platform's
// builder and the GWT harness both rewrite a projection's actions — but a
// deployed state-view slice assembles its own JSON-level operations, so the
// synthetic column stayed null on AWS and every surface named the row by its id.
//
// The same gap, and for the same reason, as the union stamp beside it.

open JestGlobals

@schema
type rowState = {
  orderId: string,
  placedAt: string,
  shippedAt: string,
  displayName: option<string>,
}

// The same state with no `@displayName` on any of its fields.
let plainRowStateSchema = rowStateSchema

// What the ppx emits for `@displayName placedAt`.
let rowStateSchema =
  rowStateSchema->S.Metadata.set(
    ~id=Reventless.DisplayName.displayNameId,
    {Reventless.DisplayName.fields: ["placedAt"], separator: " "},
  )

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

let labelOf = (json: JSON.t) =>
  json
  ->JSON.Decode.object
  ->Option.flatMap(o => o->Dict.get("displayName"))
  ->Option.flatMap(JSON.Decode.string)

let row = (~placedAt="2026-09-07T13:57:46.593Z"): JSON.t =>
  ({orderId: "o1", placedAt, shippedAt: "", displayName: None}: rowState)
  ->ReventlessCore.Message.encode(rowStateSchema)

describe("ProjectionEntryPoint_Ops.withDisplayName", () => {
  testPromise("composes the label on save", async () => {
    let (base, saved) = capture()
    let ops =
      base->ProjectionEntryPoint_Ops.withDisplayName(
        ~stateSchema=Some(rowStateSchema->S.castToUnknown),
      )
    let _ = await ops.save("o1", row(), ReventlessCore.QueryDb.Any, None)
    expect(saved->Array.get(0)->Option.flatMap(labelOf))->toEqual(Some("2026-09-07T13:57:46.593Z"))
  })

  // saveBatch is the path a multi-event projection takes, and it was missing the
  // overlay for the same reason save was.
  testPromise("composes the label for every row in a batch", async () => {
    let (base, saved) = capture()
    let ops =
      base->ProjectionEntryPoint_Ops.withDisplayName(
        ~stateSchema=Some(rowStateSchema->S.castToUnknown),
      )
    let _ = await ops.saveBatch([("o1", row(), None), ("o2", row(~placedAt="2026-09-08T09:00:00Z"), None)])
    expect(saved->Array.map(labelOf))->toEqual([
      Some("2026-09-07T13:57:46.593Z"),
      Some("2026-09-08T09:00:00Z"),
    ])
  })

  // A state that declares no `@displayName` is left exactly as it was — the
  // wrapper is applied to every slice, annotated or not.
  testPromise("passes rows through when the state declares no label", async () => {
    let (base, saved) = capture()
    let ops =
      base->ProjectionEntryPoint_Ops.withDisplayName(
        ~stateSchema=Some(plainRowStateSchema->S.castToUnknown),
      )
    let _ = await ops.save("o1", row(), ReventlessCore.QueryDb.Any, None)
    expect(saved->Array.get(0)->Option.flatMap(labelOf))->toEqual(None)
  })
})
