// Parity guard for the tag-extraction reshape: `extractTags`/`extractTagsExpanded`
// swap the per-message `JSON.stringifyAny -> parseOrThrow` round-trip for the
// schema-aware `Util_Sury.toJson`. The two must feed the tag
// walkers (`extractTagsFromJson` / `extractTagsFromJsonExpanded`) identically.
// This test builds the JSON both ways and asserts the extracted tags agree
// across representative shapes (scalar/int/array tags, key overrides, @as
// renames, payload-less variants, and plain-object non-union events), plus the
// concrete expected tags.

open JestGlobals

let viaStringify = value => value->JSON.stringifyAny->Option.getOrThrow->JSON.parseOrThrow

module Scalar = {
  @schema
  type event =
    | CategoryAdded({categoryId: @s.matches(DcbTag.string) string, name: string})
    | CategoryArchived({categoryId: @s.matches(DcbTag.string) string})
}

module IntTag = {
  @schema
  type event = Counted({widgetId: @s.matches(DcbTag.int) int})
}

module ArrayTag = {
  @schema
  type command =
    PlaceOrder({
      orderId: @s.matches(DcbTag.string) string,
      productIds: array<@s.matches(DcbTag.stringForKey(~key="productId")) string>,
    })
}

module Renamed = {
  // A tagged field carrying an @as rename: stringifyAny would emit the runtime
  // key, reverseConvert emits the serialized ("as") key. The schema's property
  // dict is keyed by the serialized name, so reverseConvert is the correct feed.
  @schema
  type event = Renamed({@as("category_id") categoryId: @s.matches(DcbTag.string) string})
}

module PayloadLess = {
  @schema
  type event =
    | ProductAdded({productId: @s.matches(DcbTag.string) string})
    | Discontinued
}

module PlainObject = {
  @schema
  type event = {orderId: @s.matches(DcbTag.string) string, note: string}
}

let unk = s => s->S.castToUnknown

describe("DcbTag.extractTags reverseConvert parity", () => {
  testSync("scalar string tag: reverse-json == stringify-json for extraction", () => {
    let v = Scalar.CategoryAdded({categoryId: "cat-1", name: "Electronics"})
    let r = v->Util_Sury.toJson(Scalar.eventSchema)
    let s = viaStringify(v)
    expect(DcbTag.extractTagsFromJson(Scalar.eventSchema->unk, r))->toEqual(
      DcbTag.extractTagsFromJson(Scalar.eventSchema->unk, s),
    )
    expect(DcbTag.extractTagsFromJson(Scalar.eventSchema->unk, r))->toEqual([
      {DcbTag.key: "categoryId", value: "cat-1"},
    ])
  })

  testSync("int tag", () => {
    let v = IntTag.Counted({widgetId: 42})
    let r = v->Util_Sury.toJson(IntTag.eventSchema)
    let s = viaStringify(v)
    expect(DcbTag.extractTagsFromJson(IntTag.eventSchema->unk, r))->toEqual(
      DcbTag.extractTagsFromJson(IntTag.eventSchema->unk, s),
    )
    expect(DcbTag.extractTagsFromJson(IntTag.eventSchema->unk, r))->toEqual([
      {DcbTag.key: "widgetId", value: "42"},
    ])
  })

  testSync("payload-less variant present in the union", () => {
    let v = PayloadLess.ProductAdded({productId: "p-1"})
    let r = v->Util_Sury.toJson(PayloadLess.eventSchema)
    let s = viaStringify(v)
    expect(DcbTag.extractTagsFromJson(PayloadLess.eventSchema->unk, r))->toEqual(
      DcbTag.extractTagsFromJson(PayloadLess.eventSchema->unk, s),
    )
  })

  testSync("plain object (non-union) event", () => {
    let v: PlainObject.event = {orderId: "o-1", note: "hi"}
    let r = v->Util_Sury.toJson(PlainObject.eventSchema)
    let s = viaStringify(v)
    expect(DcbTag.extractTagsFromJson(PlainObject.eventSchema->unk, r))->toEqual(
      DcbTag.extractTagsFromJson(PlainObject.eventSchema->unk, s),
    )
    expect(DcbTag.extractTagsFromJson(PlainObject.eventSchema->unk, r))->toEqual([
      {DcbTag.key: "orderId", value: "o-1"},
    ])
  })

  testSync("array tag expands per element (extractTagsFromJsonExpanded)", () => {
    let v = ArrayTag.PlaceOrder({orderId: "ord-1", productIds: ["p1", "p2"]})
    let r = v->Util_Sury.toJson(ArrayTag.commandSchema)
    let s = viaStringify(v)
    expect(DcbTag.extractTagsFromJsonExpanded(ArrayTag.commandSchema->unk, r))->toEqual(
      DcbTag.extractTagsFromJsonExpanded(ArrayTag.commandSchema->unk, s),
    )
    expect(DcbTag.extractTagsFromJsonExpanded(ArrayTag.commandSchema->unk, r))->toEqual([
      {DcbTag.key: "orderId", value: "ord-1"},
      {DcbTag.key: "productId", value: "p1"},
      {DcbTag.key: "productId", value: "p2"},
    ])
  })

  testSync("@as-renamed tagged field: reverseConvert feeds the serialized key", () => {
    let v = Renamed.Renamed({categoryId: "cat-9"})
    let r = v->Util_Sury.toJson(Renamed.eventSchema)
    // The extractor keys tags off the schema property name; with reverseConvert
    // the JSON carries the serialized "category_id" key so the field is found.
    expect(DcbTag.extractTagsFromJson(Renamed.eventSchema->unk, r))->toEqual([
      {DcbTag.key: "category_id", value: "cat-9"},
    ])
  })
})
