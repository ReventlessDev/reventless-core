// What a DCB event log tells its readers it carries.
//
// A plugin's slices all append to ONE log, but each slice declares only its own
// events. The log's schema entry used to be the first slice's schema, taken as
// representative — and every reader of that entry believed it: the upload
// claimer granted and untagged refs for one slice's events, and MCP described
// the log's history as carrying that slice's event types and no others. Nothing
// failed; the rest was simply invisible, which for the claimer means objects
// that keep their pending tag and expire while an event references them.
//
// So the assertions here are about completeness, and about the shape that
// completeness has to arrive in: readers walk exactly one level, `Union` →
// per-variant `Object` with a `TAG`, so a union of unions would be as blind as
// the single schema it replaced while looking like it covered everything.

open JestGlobals

let variant = (~tag: string, fields: array<(string, S.t<unknown>)>): S.t<unknown> =>
  S.object(s => {
    let _ = s.field("TAG", S.literal(tag)->S.castToUnknown)
    fields->Array.forEach(((name, schema)) => {
      let _ = s.field(name, schema)
    })
    ()
  })->S.castToUnknown

let ref_ = (~store: string) => Reventless.StorageRef.forStore(~store)->S.castToUnknown

let addCategory = S.union([
  variant(~tag="CategoryAdded", [("imageUrl", ref_(~store="categoryImages"))]),
])->S.castToUnknown

let addProduct = S.union([
  variant(~tag="ProductAdded", [("imageUrl", ref_(~store="productImages"))]),
])->S.castToUnknown

let renameCategory = S.union([
  variant(~tag="CategoryRenamed", [("name", S.string->S.castToUnknown)]),
])->S.castToUnknown

describe("Dcb_Builder.mergedEventSchema", () => {
  testSync("carries every slice's event types, not the first slice's", () => {
    let merged = [addCategory, addProduct, renameCategory]->Dcb_Builder.mergedEventSchema
    expect(Reventless.DcbTag.extractVariantNames(merged))->toEqual([
      "CategoryAdded",
      "ProductAdded",
      "CategoryRenamed",
    ])
  })

  // The claimer's whole input. One slice short here is a store's objects
  // expiring under a live reference.
  testSync("surfaces the ref fields of every slice that declares one", () => {
    let merged = [addCategory, addProduct, renameCategory]->Dcb_Builder.mergedEventSchema
    expect(
      StorageRefFields.fromEventSchema(~plugin="Catalog", merged)->Array.map(e => (
        e.eventType,
        e.fields->Array.map(f => f.store),
      )),
    )->toEqual([
      ("CategoryAdded", ["Catalog.categoryImages"]),
      ("ProductAdded", ["Catalog.productImages"]),
    ])
  })

  // Two slices producing the same event would otherwise hand sury two arms
  // under one discriminant, and every reader a duplicate.
  testSync("keeps one arm per event type", () => {
    let merged = [addProduct, addProduct]->Dcb_Builder.mergedEventSchema
    expect(Reventless.DcbTag.extractVariantNames(merged))->toEqual(["ProductAdded"])
  })

  testSync("leaves a lone slice's schema as it is", () => {
    let merged = [addProduct]->Dcb_Builder.mergedEventSchema
    expect(Reventless.DcbTag.extractVariantNames(merged))->toEqual(["ProductAdded"])
  })
})
