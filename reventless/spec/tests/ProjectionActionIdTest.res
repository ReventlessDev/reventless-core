// The storage edge converts a typed row key to the string a table is keyed by,
// and back for the ids an action's callbacks receive. Both directions have to
// land on every constructor, or a typed projection writes to the wrong row.

open JestGlobals

module OrderId = Id.Make({
  let key = "orderId"
})

let toString = a => a->Projection.mapActionId(~to_=OrderId.toString, ~from=OrderId.makeFromString)
let o = OrderId.makeFromString

describe("Projection.mapActionId", () => {
  testSync("converts the ids an action carries", () => {
    switch toString(Set(o("o-1"), 1)) {
    | Set(id, state) => expect((id, state))->toEqual(("o-1", 1))
    | _ => fail("expected Set")
    }
    switch toString(DeleteMany([o("o-1"), o("o-2")])) {
    | DeleteMany(ids) => expect(ids)->toEqual(["o-1", "o-2"])
    | _ => fail("expected DeleteMany")
    }
  })

  testSync("hands the callbacks the typed id back", () => {
    let seen = []
    switch toString(
      UpdateMany(
        [o("o-1")],
        (id, state) => {
          seen->Array.push(id->OrderId.toString)
          state + 1
        },
      ),
    ) {
    | UpdateMany(ids, f) => expect((ids, f("o-1", 1), seen))->toEqual((["o-1"], 2, ["o-1"]))
    | _ => fail("expected UpdateMany")
    }
  })

  testSync("leaves Ignore alone", () =>
    switch toString(Ignore) {
    | Ignore => expect(true)->toBe(true)
    | _ => fail("expected Ignore")
    }
  )
})
