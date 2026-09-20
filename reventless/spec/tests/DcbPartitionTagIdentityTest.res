// A domain's own identifier is often not suffixed — `sku`, `isbn`, `vin` — and
// the DCB naming convention (`*Id` / `*Ids`) cannot express it. `@partitionTag`
// is meant to be the escape hatch for exactly that, but it used to work only
// where it was not needed: the hint was extracted from the event schema and then
// dropped, because `seedOf` honours a hint only when it already names a produced
// key, and produced keys came from names alone.
//
// So a slice keyed by `sku` had an annotation in its source, a partition the
// author did not choose, and nothing anywhere saying the two disagreed.

open JestGlobals

let unk = s => s->S.castToUnknown

module Unsuffixed = {
  @schema
  type command = ReserveStock({sku: string, quantity: int})

  @schema
  type consumedEvent = StockReserved({sku: string})

  @schema
  type event = StockReserved({sku: @s.matches(DcbTag.partition) string, quantity: int})
}

let shapeOf = () =>
  DcbTag.sliceShapeFromSchemas(
    ~name="ReserveStock",
    ~commandSchema=Unsuffixed.commandSchema->unk,
    ~consumedEventSchema=Unsuffixed.consumedEventSchema->unk,
    ~eventSchema=Unsuffixed.eventSchema->unk,
  )

describe("an explicit partition tag declares an identity the name cannot", () => {
  testSync("the tagged field becomes a produced key", () => {
    // Without this the set is empty: `sku` is not `*Id`-shaped, so the slice has
    // nothing to be partitioned by at all.
    expect(DcbScopeInference.producedKeys(shapeOf()))->toEqual(["sku"])
  })

  testSync("it is marked as an identity the annotation brought", () => {
    // Load-bearing: removing the annotation removes the identity, which the
    // redundancy check has to be able to tell apart from a name-derived one.
    let f =
      shapeOf().produced
      ->Array.flatMap(e => e.idFields)
      ->Array.find(f => f.name == "sku")
      ->Option.getOrThrow
    expect(f.byTag)->toEqual(Some(true))
  })

  testSync("the slice resolves to it", () =>
    expect(
      DcbScopeInference.resolvePartitions([shapeOf()]).partitionBySlice->Dict.get("ReserveStock"),
    )->toEqual(Some("sku"))
  )

  testSync("a name-derived key is not marked", () => {
    // The flag says "only an identity because of the tag" — a `*Id` field stays
    // an identity with the annotation gone, so tagging one must not set it.
    let shape: DcbScopeInference.sliceShape = {
      sliceName: "S",
      command: [],
      consumed: [],
      produced: [{eventType: "E", idFields: [{name: "orderId", isList: false}]}],
      partitionHint: None,
    }
    expect(
      shape.produced->Array.flatMap(e => e.idFields)->Array.every(f => f.byTag != Some(true)),
    )->toBe(true)
  })
})

describe("the redundancy check knows what the annotation is holding up", () => {
  testSync("a tag that is the only reason for the key is not called redundant", () => {
    // "Inference reaches the same key without the annotation" has to mean
    // without everything the annotation brought. Dropping only the hint would
    // leave `sku` in the shape, inference would reach it, and the author would
    // be told to remove the one line making the slice work.
    let issues = DcbValidation.validatePartitionHintsVsInference(~shapes=[shapeOf()])
    expect(issues.redundancies->Array.length)->toBe(0)
    expect(issues.contradictions->Array.length)->toBe(0)
  })

  testSync("a tag on a name-derived key is still called redundant", () => {
    // The existing rule, unchanged: here the annotation adds nothing, because
    // `orderId` is an identity with or without it.
    let shape: DcbScopeInference.sliceShape = {
      sliceName: "PlaceOrder",
      command: [{name: "orderId", isList: false}],
      consumed: [],
      produced: [{eventType: "OrderPlaced", idFields: [{name: "orderId", isList: false}]}],
      partitionHint: Some("orderId"),
    }
    let issues = DcbValidation.validatePartitionHintsVsInference(~shapes=[shape])
    expect(issues.redundancies->Array.length)->toBe(1)
  })
})
