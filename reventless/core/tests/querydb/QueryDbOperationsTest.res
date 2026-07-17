open JestGlobals
open QueryDbFixtures

module Ops = QueryDb_Operations.Make(
  ItemQueryDbSpec,
  {
    let jsonOps = mockJsonOps
  },
)

let _ = beforeEach(() => reset())

describe("QueryDb_Operations:", () => {
  describe("loadStream", () => {
    testPromise("returns empty stream for unknown id", async () => {
      let result = await Ops.loadStream("unknown-id")->Stream.runCollect->Effect.runPromise
      expect(result)->toEqual([])
    })

    testPromise("decodes saved state back to typed state", async () => {
      let state: ItemQueryDbSpec.state = {name: "Widget", count: 5}
      let _ = await Ops.save("item-1", state, Init, None)
      let result = await Ops.loadStream("item-1")->Stream.runCollect->Effect.runPromise
      switch result {
      | [s] => expect((s.name, s.count))->toEqual(("Widget", 5))
      | _ => expect("unexpected result")->toEqual("Ok([state])")
      }
    })

    testPromise("returns updated state after overwrite", async () => {
      let _ = await Ops.save("item-1", {name: "Widget", count: 1}, Init, None)
      let _ = await Ops.save("item-1", {name: "Widget Updated", count: 2}, Overwrite, None)
      let result = await Ops.loadStream("item-1")->Stream.runCollect->Effect.runPromise
      switch result {
      | [s] => expect(s.name)->toBe("Widget Updated")
      | _ => expect("unexpected result")->toEqual("Ok([state])")
      }
    })
  })

  describe("save", () => {
    testPromise("returns Ok on success", async () => {
      let result = await Ops.save("item-1", {name: "Widget", count: 1}, Init, None)
      expect(Result.isOk(result))->toBe(true)
    })

    testPromise("stores id field in JSON", async () => {
      let _ = await Ops.save("item-42", {name: "Widget", count: 0}, Init, None)
      let stored = store.contents->Dict.get("item-42")->Option.getOr([])
      expect(stored->Array.length)->toBe(1)
      let json = stored->Array.getUnsafe(0)
      let idField =
        json
        ->JSON.Decode.object
        ->Option.flatMap(d => d->Dict.get("id"))
        ->Option.flatMap(j => switch j { | JSON.String(s) => Some(s) | _ => None })
      expect(idField)->toEqual(Some("item-42"))
    })

    testPromise("returns Error when storage fails", async () => {
      failNextWrite := true
      let result = await Ops.save("item-1", {name: "Widget", count: 1}, Init, None)
      expect(Result.isError(result))->toBe(true)
    })
  })

  describe("saveBatch", () => {
    testPromise("saves multiple states", async () => {
      let batch = [
        ("item-1", ({name: "A", count: 1}: ItemQueryDbSpec.state), None),
        ("item-2", ({name: "B", count: 2}: ItemQueryDbSpec.state), None),
      ]
      let _ = await Ops.saveBatch(batch)
      let r1 = await Ops.loadStream("item-1")->Stream.runCollect->Effect.runPromise
      let r2 = await Ops.loadStream("item-2")->Stream.runCollect->Effect.runPromise
      expect((r1->Array.length > 0, r2->Array.length > 0))->toEqual((true, true))
    })

    testPromise("returns Error when storage fails", async () => {
      failNextWrite := true
      let result = await Ops.saveBatch([("item-1", ({name: "A", count: 1}: ItemQueryDbSpec.state), None)])
      expect(Result.isError(result))->toBe(true)
    })
  })

  describe("delete", () => {
    testPromise("removes state from storage", async () => {
      let _ = await Ops.save("item-1", {name: "Widget", count: 1}, Init, None)
      let _ = await Ops.delete("item-1", None)
      let result = await Ops.loadStream("item-1")->Stream.runCollect->Effect.runPromise
      expect(result)->toEqual([])
    })
  })
})
