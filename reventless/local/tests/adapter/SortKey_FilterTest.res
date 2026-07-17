// Unit tests for SortKey_Filter — the pure sort key filtering utility.

open JestGlobals

let makeItem = (sk: string) => {
  let d = Dict.make()
  d->Dict.set("_subId", JSON.Encode.string(sk))
  JSON.Encode.object(d)
}

let items = [
  makeItem("art/2026-01"),
  makeItem("art/2026-02"),
  makeItem("math/2026-01"),
  makeItem("math/2026-02"),
  makeItem("science/2026-01"),
]

let skField = "_subId"

let getSks = result =>
  result.SortKey_Filter.items->Array.map(item =>
    item->JSON.Decode.object->Option.flatMap(d => d->Dict.get(skField))->Option.flatMap(JSON.Decode.string)->Option.getOr("")
  )

describe("SortKey_Filter.apply:", () => {
  testPromise("no filters returns all items in order", async () => {
    let r = SortKey_Filter.apply(~items, ~skField)
    expect(r.items->Array.length)->toBe(5)
    expect(getSks(r))->toEqual(["art/2026-01", "art/2026-02", "math/2026-01", "math/2026-02", "science/2026-01"])
    expect(r.nextToken)->toBe(None)
  })

  testPromise("prefix filters to matching sort keys", async () => {
    let r = SortKey_Filter.apply(~items, ~skField, ~prefix="math")
    expect(getSks(r))->toEqual(["math/2026-01", "math/2026-02"])
    expect(r.nextToken)->toBe(None)
  })

  testPromise("from filters to sort keys >= from", async () => {
    let r = SortKey_Filter.apply(~items, ~skField, ~from="math/2026-01")
    expect(getSks(r))->toEqual(["math/2026-01", "math/2026-02", "science/2026-01"])
  })

  testPromise("to filters to sort keys <= to", async () => {
    let r = SortKey_Filter.apply(~items, ~skField, ~to_="art/2026-02")
    expect(getSks(r))->toEqual(["art/2026-01", "art/2026-02"])
  })

  testPromise("from+to gives BETWEEN range", async () => {
    let r = SortKey_Filter.apply(~items, ~skField, ~from="art/2026-02", ~to_="math/2026-01")
    expect(getSks(r))->toEqual(["art/2026-02", "math/2026-01"])
  })

  testPromise("eq filters to exact match only", async () => {
    let r = SortKey_Filter.apply(~items, ~skField, ~eq="math/2026-02")
    expect(getSks(r))->toEqual(["math/2026-02"])
  })

  testPromise("reverse returns items in descending order", async () => {
    let r = SortKey_Filter.apply(~items, ~skField, ~reverse=true)
    expect(getSks(r))->toEqual(["science/2026-01", "math/2026-02", "math/2026-01", "art/2026-02", "art/2026-01"])
  })

  testPromise("limit returns first N items", async () => {
    let r = SortKey_Filter.apply(~items, ~skField, ~limit=2)
    expect(getSks(r))->toEqual(["art/2026-01", "art/2026-02"])
    expect(r.nextToken)->toBe(Some("2"))
  })

  testPromise("nextToken resumes from offset", async () => {
    let r = SortKey_Filter.apply(~items, ~skField, ~limit=2, ~offset=2)
    expect(getSks(r))->toEqual(["math/2026-01", "math/2026-02"])
    expect(r.nextToken)->toBe(Some("4"))
  })

  testPromise("last page has no nextToken", async () => {
    let r = SortKey_Filter.apply(~items, ~skField, ~limit=2, ~offset=4)
    expect(getSks(r))->toEqual(["science/2026-01"])
    expect(r.nextToken)->toBe(None)
  })

  testPromise("prefix + limit + nextToken paginates correctly", async () => {
    let r1 = SortKey_Filter.apply(~items, ~skField, ~prefix="art", ~limit=1)
    expect(getSks(r1))->toEqual(["art/2026-01"])
    expect(r1.nextToken)->toBe(Some("1"))
    let r2 = SortKey_Filter.apply(~items, ~skField, ~prefix="art", ~limit=1, ~offset=1)
    expect(getSks(r2))->toEqual(["art/2026-02"])
    expect(r2.nextToken)->toBe(None)
  })

  testPromise("reverse + limit returns last N items", async () => {
    let r = SortKey_Filter.apply(~items, ~skField, ~reverse=true, ~limit=3)
    expect(getSks(r))->toEqual(["science/2026-01", "math/2026-02", "math/2026-01"])
    expect(r.nextToken)->toBe(Some("3"))
  })

  testPromise("eq with no match returns empty", async () => {
    let r = SortKey_Filter.apply(~items, ~skField, ~eq="nonexistent")
    expect(r.items->Array.length)->toBe(0)
    expect(r.nextToken)->toBe(None)
  })
})
