// The backfill of a view table's derived trail dates: which rows it updates, the
// update it sends, and that a row written in the meantime is skipped.

open JestGlobals

module Rederive = ReventlessSeedAws_Rederive

let row = (json: string): dict<JSON.t> =>
  json->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow

let trail = `[{"state":"Placed","at":"2026-03-02T09:00:00Z"},{"state":"Shipped","at":"2026-03-02T10:00:00Z"}]`

/** A table in memory, paged two rows at a time, whose update applies the
    expression's SET and REMOVE, honouring the trail-length condition. */
let table = (rows: array<dict<JSON.t>>, ~onUpdate: dict<JSON.t> => unit=_ => ()): (
  Rederive.ops,
  ref<int>,
) => {
  let updates = ref(0)
  let ops: Rederive.ops = {
    scan: async start => {
      let from = start->Option.flatMap(k => k->Dict.get("at"))->Option.flatMap(JSON.Decode.float)
      let from = from->Option.mapOr(0, Float.toInt)
      let page = rows->Array.slice(~start=from, ~end=from + 2)
      let next =
        from + 2 < rows->Array.length
          ? Some(Dict.fromArray([("at", JSON.Encode.int(from + 2))]))
          : None
      (page->Array.map(Dict.copy), next)
    },
    update: async input => {
      let id = input.key->Dict.get("id")
      let stored = rows->Array.find(r => r->Dict.get("id") == id)->Option.getOrThrow
      stored->onUpdate
      let names = input.expressionAttributeNames->Option.getOrThrow
      let values = input.expressionAttributeValues->Option.getOrThrow
      let length = switch stored->Dict.get(names->Dict.get("#trail")->Option.getOrThrow) {
      | Some(Array(entries)) => entries->Array.length
      | _ => -1
      }
      if Some(JSON.Encode.int(length)) != values->Dict.get(":length") {
        Rederive.Skipped
      } else {
        names->Dict.forEachWithKey((attr, token) =>
          if token->String.startsWith("#s") {
            let value = values->Dict.get(":" ++ token->String.slice(~start=1))->Option.getOrThrow
            stored->Dict.set(attr, value)
          } else if token->String.startsWith("#r") {
            stored->Dict.delete(attr)
          }
        )
        updates := updates.contents + 1
        Rederive.Updated
      }
    },
  }
  (ops, updates)
}

describe("updateFor", () => {
  testSync("sets the derived attributes, conditioned on the trail's length", () => {
    let input =
      Rederive.updateFor(
        ~table="Orders",
        ~keyAttrs=["id"],
        row(`{"id":"o1","trail":${trail}}`),
      )->Option.getOrThrow
    expect(input.key)->toEqual(Dict.fromArray([("id", JSON.Encode.string("o1"))]))
    expect(input.conditionExpression)->toEqual(Some("size(#trail) = :length"))
    expect(input.expressionAttributeValues->Option.flatMap(v => v->Dict.get(":length")))->toEqual(
      Some(JSON.Encode.int(2)),
    )
    expect(input.updateExpression->Option.getOr("")->String.startsWith("SET #s0 = :s0"))->toBe(true)
    expect(
      input.expressionAttributeNames
      ->Option.getOrThrow
      ->Dict.valuesToArray
      ->Array.toSorted(String.compare),
    )->toEqual([
      "_entered_Placed",
      "_entered_Placed_first",
      "_entered_Shipped",
      "_entered_Shipped_first",
      "_entered_current",
      "_trail",
      "_visits_Placed",
      "_visits_Shipped",
      "trail",
    ])
  })

  testSync("removes a date the trail no longer gives", () => {
    let r = row(`{"id":"o1","trail":${trail}}`)
    r->Reventless.Lifecycle.Trail.writeDerived(~field="trail")
    r->Dict.set("_entered_Cancelled", JSON.Encode.string("2026-03-01T00:00:00Z"))
    let input = Rederive.updateFor(~table="Orders", ~keyAttrs=["id"], r)->Option.getOrThrow
    expect(input.updateExpression)->toEqual(Some("REMOVE #r0"))
  })

  testSync("leaves a current row and a row without a trail alone", () => {
    let current = row(`{"id":"o1","trail":${trail}}`)
    current->Reventless.Lifecycle.Trail.writeDerived(~field="trail")
    expect(Rederive.updateFor(~table="Orders", ~keyAttrs=["id"], current))->toEqual(None)
    expect(Rederive.updateFor(~table="Orders", ~keyAttrs=["id"], row(`{"id":"t1"}`)))->toEqual(None)
  })
})

describe("rederiveTable", () => {
  let rows = () => [
    row(`{"id":"o1","trail":${trail}}`),
    row(`{"id":"o2","trail":${trail}}`),
    row(`{"id":"o3"}`),
    row(`{"id":"o4","trail":${trail}}`),
  ]

  test("a dry run counts across pages and writes nothing", async () => {
    let (ops, updates) = table(rows())
    let t = await Rederive.rederiveTable(~table="Orders", ~keyAttrs=["id"], ~apply=false, ops)
    expect((t.rows, t.withTrail, t.toChange, t.updated, updates.contents))->toEqual((4, 3, 3, 0, 0))
  })

  test("applying writes each row once, and a second run finds nothing", async () => {
    let (ops, _) = table(rows())
    let first = await Rederive.rederiveTable(~table="Orders", ~keyAttrs=["id"], ~apply=true, ops)
    expect((first.toChange, first.updated, first.skipped))->toEqual((3, 3, 0))
    let second = await Rederive.rederiveTable(~table="Orders", ~keyAttrs=["id"], ~apply=true, ops)
    expect((second.toChange, second.updated))->toEqual((0, 0))
  })

  test("skips a row whose trail grew after the scan", async () => {
    let grow = stored =>
      if stored->Dict.get("id") == Some(JSON.Encode.string("o2")) {
        stored->Reventless.Lifecycle.Trail.record(
          ~field="trail",
          ~state=JSON.Encode.string("Cancelled"),
          ~at="2026-03-02T11:00:00Z",
        )
      }
    let (ops, _) = table(rows(), ~onUpdate=grow)
    let t = await Rederive.rederiveTable(~table="Orders", ~keyAttrs=["id"], ~apply=true, ops)
    expect((t.toChange, t.updated, t.skipped))->toEqual((3, 2, 1))
  })
})
