// The half of reconciliation that decides whether an object is referenced.
//
// Everything else in the report is counting; `collectRefs` is the judgement, and
// it is judgement in one direction only. A ref it misses turns a live object
// into an "unreferenced, tagged pending" row — which is the row an operator
// reads as permission to enable an expiry rule. A ref it collects too eagerly
// only ever leaves an object alive.
//
// So these tests are about reach: nesting, arrays, records, and the prefix
// boundary that separates one store from another.

open JestGlobals

module Reconcile = ReventlessSeedAws_Reconcile

let prefix = "Catalog/productImages"
let refIn = "/Catalog/productImages/user-1/uuid/photo.png"
let refOther = "/Ordering/receipts/user-1/uuid/r.pdf"

let collect = (json: JSON.t): array<string> => {
  let out = Set.make()
  Reconcile.collectRefs(~prefix, json, out)
  out->Set.toArray
}

let obj = (fields: array<(string, JSON.t)>) => fields->Dict.fromArray->JSON.Encode.object

describe("ReventlessSeedAws_Reconcile.collectRefs", () => {
  testSync("finds a ref on a top-level field", () =>
    expect(collect(obj([("imageUrl", JSON.Encode.string(refIn))])))->toEqual([refIn])
  )

  // Deliberately not declaration-driven: the claim component reads `@storageRef`
  // annotations, so a report reading the same list would inherit the same blind
  // spot and agree precisely where both are wrong. An unannotated field holding a
  // ref has to show up here, as the thing to fix before expiry goes on.
  testSync("finds a ref on a field no annotation would have named", () =>
    expect(collect(obj([("someUndeclaredField", JSON.Encode.string(refIn))])))->toEqual([refIn])
  )

  testSync("finds refs inside an array", () =>
    expect(collect(obj([("images", JSON.Encode.array([JSON.Encode.string(refIn)]))])))->toEqual([
      refIn,
    ])
  )

  testSync("finds a ref nested inside a record", () =>
    expect(collect(obj([("variant", obj([("photo", JSON.Encode.string(refIn))]))])))->toEqual([refIn])
  )

  // Store isolation: one bucket holds several stores under distinct prefixes, so
  // a reconciliation scoped to one store must not count another's refs — that
  // would mark a genuinely abandoned object as referenced and hide it forever.
  testSync("ignores a ref belonging to another store", () =>
    expect(collect(obj([("receipt", JSON.Encode.string(refOther))])))->toEqual([])
  )

  // The prefix boundary is a path segment, not a string prefix.
  testSync("ignores a store whose name merely starts the same way", () =>
    expect(
      collect(obj([("x", JSON.Encode.string("/Catalog/productImagesArchive/u/i/p.png"))])),
    )->toEqual([])
  )

  testSync("ignores strings that are not refs at all", () =>
    expect(
      collect(
        obj([
          ("name", JSON.Encode.string("A product")),
          ("external", JSON.Encode.string("https://example.com/Catalog/productImages/p.png")),
          ("count", JSON.Encode.int(3)),
        ]),
      ),
    )->toEqual([])
  )

  testSync("collects each distinct ref once", () => {
    let json = obj([
      ("a", JSON.Encode.string(refIn)),
      ("b", JSON.Encode.string(refIn)),
    ])
    expect(collect(json)->Array.length)->toBe(1)
  })
})
