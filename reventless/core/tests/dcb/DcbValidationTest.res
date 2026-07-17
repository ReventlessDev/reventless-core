open JestGlobals

// Test schemas for produced events
@schema
type producedA =
  | ItemCreated({itemId: @s.matches(Reventless.DcbTag.string) string, name: string})
  | ItemRenamed({itemId: @s.matches(Reventless.DcbTag.string) string, newName: string})

@schema
type producedB =
  | ItemArchived({itemId: @s.matches(Reventless.DcbTag.string) string})

// A second producer for ItemCreated with matching fields/tags
@schema
type producedADuplicate =
  | ItemCreated({itemId: @s.matches(Reventless.DcbTag.string) string, name: string})

// A second producer for ItemCreated with DIFFERENT fields (missing name)
@schema
type producedAMismatchFields =
  | ItemCreated({itemId: @s.matches(Reventless.DcbTag.string) string})

// A second producer for ItemCreated with mismatched tag annotations
@schema
type producedAMismatchTags =
  | ItemCreated({itemId: string, name: string})

// A second producer for ItemCreated with mismatched field type
@schema
type producedAMismatchType =
  | ItemCreated({itemId: @s.matches(Reventless.DcbTag.string) string, name: float})

// Consumed events — full shape
@schema
type consumedFull =
  | ItemCreated({itemId: string, name: string})
  | ItemRenamed({itemId: string, newName: string})

// Consumed events — partial projection (only itemId)
@schema
type consumedPartial =
  | ItemCreated({itemId: string})

// Consumed events — payload-less
@schema
type consumedPayloadLess =
  | ItemCreated
  | ItemArchived

// Consumed events — references nonexistent producer
@schema
type consumedDangling =
  | ItemDeleted({itemId: string})

// Consumed events — field not in produced shape
@schema
type consumedBadField =
  | ItemCreated({itemId: string, rating: float})

// Consumed events — type mismatch
@schema
type consumedBadType =
  | ItemCreated({itemId: string, name: float})

// --- Composite-read (Issue 5) fixtures ---

// All-scalar two-tag command → composite (tag_composite) decision read.
@schema
type recordDemandCommand =
  | RecordDemand({
      productId: @s.matches(Reventless.DcbTag.string) string,
      orderId: @s.matches(Reventless.DcbTag.string) string,
    })

// Single-tag command → partition read, never composite.
@schema
type touchDemandCommand =
  | TouchDemand({productId: @s.matches(Reventless.DcbTag.string) string})

// Tagged-array command → per-element OR (single-tag) clauses, never composite.
@schema
type placeOrderCommand =
  | PlaceOrder({
      orderId: @s.matches(Reventless.DcbTag.string) string,
      productIds: array<@s.matches(Reventless.DcbTag.stringForKey(~key="productId")) string>,
    })

// Consumed shape — names only matter; tags may be under-declared on consumers.
@schema
type demandConsumed =
  | ProductDemandRecorded({productId: string, orderId: string})
  | ProductDemandRevoked({productId: string, orderId: string})

// Produced event-log schema: ProductDemandRecorded carries exactly the query's
// tags; ProductDemandRevoked carries an EXTRA customerId tag (strict superset).
@schema
type demandProduced =
  | ProductDemandRecorded({
      productId: @s.matches(Reventless.DcbTag.string) string,
      orderId: @s.matches(Reventless.DcbTag.string) string,
    })
  | ProductDemandRevoked({
      productId: @s.matches(Reventless.DcbTag.string) string,
      orderId: @s.matches(Reventless.DcbTag.string) string,
      customerId: @s.matches(Reventless.DcbTag.string) string,
    })

let validate = Reventless.DcbValidation.validateProducedAndConsumed
let u = S.castToUnknown
let producedTagKeys = Reventless.DcbTag.extractTagKeysByEventType(demandProducedSchema)

// Cross-partition scope fixtures (Issue 13 / Phase 7). studentId is declared
// @crossPartition on one producer; a second producer that carries studentId
// must declare the same scope or the (writer-driven) fence is ambiguous.
@schema
type subscribedCrossPartition =
  | StudentSubscribed({
      courseId: @s.matches(Reventless.DcbTag.partition) string,
      studentId: @s.matches(Reventless.DcbTag.crossPartition) string,
    })

// Agreeing producer: also carries studentId as @crossPartition.
@schema
type unsubscribedCrossPartition =
  | StudentUnsubscribed({
      courseId: @s.matches(Reventless.DcbTag.partition) string,
      studentId: @s.matches(Reventless.DcbTag.crossPartition) string,
    })

// Disagreeing producer: carries studentId but partition-scoped (plain tag).
@schema
type flaggedPartitionScoped =
  | StudentFlagged({
      studentId: @s.matches(Reventless.DcbTag.partition) string,
      courseId: @s.matches(Reventless.DcbTag.string) string,
    })

describe("DcbValidation:", () => {
  describe("validateProducedAndConsumed", () => {
    testSync("passes when all consumed events match produced events", () => {
      let result = validate(
        ~produced=[("AddItem", producedASchema->u), ("ArchiveItem", producedBSchema->u)],
        ~consumed=[("ItemView", consumedFullSchema->u)],
      )
      expect(result)->toEqual(Ok())
    })

    testSync("passes with partial field projection", () => {
      let result = validate(
        ~produced=[("AddItem", producedASchema->u)],
        ~consumed=[("CheckExists", consumedPartialSchema->u)],
      )
      expect(result)->toEqual(Ok())
    })

    testSync("passes with payload-less consumed events", () => {
      let result = validate(
        ~produced=[("AddItem", producedASchema->u), ("ArchiveItem", producedBSchema->u)],
        ~consumed=[("CheckExists", consumedPayloadLessSchema->u)],
      )
      expect(result)->toEqual(Ok())
    })

    testSync("passes when multiple producers have identical shapes and tags", () => {
      let result = validate(
        ~produced=[("AddItem", producedASchema->u), ("CloneItem", producedADuplicateSchema->u)],
        ~consumed=[],
      )
      expect(result)->toEqual(Ok())
    })

    testSync("fails when consumed event has no producer", () => {
      let result = validate(
        ~produced=[("AddItem", producedASchema->u)],
        ~consumed=[("DeleteHandler", consumedDanglingSchema->u)],
      )
      switch result {
      | Error(errors) =>
        expect(errors->Array.length)->toBe(1)->ignore
        let err = errors->Array.getUnsafe(0)
        expect(err.sliceName)->toBe("DeleteHandler")->ignore
        expect(err.message->String.includes("ItemDeleted"))->toBe(true)->ignore
        expect(err.message->String.includes("no slice produces it"))->toBe(true)
      | Ok() => fail("Expected validation error")
      }
    })

    testSync("fails when consumed event references field not in produced shape", () => {
      let result = validate(
        ~produced=[("AddItem", producedASchema->u)],
        ~consumed=[("RatingView", consumedBadFieldSchema->u)],
      )
      switch result {
      | Error(errors) =>
        expect(errors->Array.length)->toBe(1)->ignore
        let err = errors->Array.getUnsafe(0)
        expect(err.sliceName)->toBe("RatingView")->ignore
        expect(err.message->String.includes("rating"))->toBe(true)->ignore
        expect(err.message->String.includes("no field"))->toBe(true)
      | Ok() => fail("Expected validation error")
      }
    })

    testSync("fails when consumed field type mismatches produced field type", () => {
      let result = validate(
        ~produced=[("AddItem", producedASchema->u)],
        ~consumed=[("BadTypeView", consumedBadTypeSchema->u)],
      )
      switch result {
      | Error(errors) =>
        expect(errors->Array.length)->toBe(1)->ignore
        let err = errors->Array.getUnsafe(0)
        expect(err.sliceName)->toBe("BadTypeView")->ignore
        expect(err.message->String.includes("name"))->toBe(true)->ignore
        expect(err.message->String.includes("float"))->toBe(true)->ignore
        expect(err.message->String.includes("string"))->toBe(true)
      | Ok() => fail("Expected validation error")
      }
    })

    testSync("fails when producers have different fields for same TAG", () => {
      let result = validate(
        ~produced=[("AddItem", producedASchema->u), ("ImportItem", producedAMismatchFieldsSchema->u)],
        ~consumed=[],
      )
      switch result {
      | Error(errors) =>
        expect(errors->Array.length)->toBeGreaterThanOrEqual(1)->ignore
        let err = errors->Array.getUnsafe(0)
        expect(err.message->String.includes("AddItem"))->toBe(true)->ignore
        expect(err.message->String.includes("ImportItem"))->toBe(true)->ignore
        expect(err.message->String.includes("name"))->toBe(true)
      | Ok() => fail("Expected validation error")
      }
    })

    testSync("fails when producers have different tag annotations for same TAG", () => {
      let result = validate(
        ~produced=[("AddItem", producedASchema->u), ("UntaggerItem", producedAMismatchTagsSchema->u)],
        ~consumed=[],
      )
      switch result {
      | Error(errors) =>
        expect(errors->Array.length)->toBeGreaterThanOrEqual(1)->ignore
        let hasTagError = errors->Array.some(err => err.message->String.includes("tag annotations"))
        expect(hasTagError)->toBe(true)
      | Ok() => fail("Expected validation error")
      }
    })

    testSync("fails when producers have different field types for same TAG", () => {
      let result = validate(
        ~produced=[("AddItem", producedASchema->u), ("BadTypeItem", producedAMismatchTypeSchema->u)],
        ~consumed=[],
      )
      switch result {
      | Error(errors) =>
        expect(errors->Array.length)->toBeGreaterThanOrEqual(1)->ignore
        let err = errors->Array.getUnsafe(0)
        expect(err.message->String.includes("name"))->toBe(true)->ignore
        expect(err.message->String.includes("string"))->toBe(true)->ignore
        expect(err.message->String.includes("float"))->toBe(true)
      | Ok() => fail("Expected validation error")
      }
    })

    testSync("passes with empty produced and consumed", () => {
      let result = validate(~produced=[], ~consumed=[])
      expect(result)->toEqual(Ok())
    })

    testSync("collects multiple errors at once", () => {
      let result = validate(
        ~produced=[("AddItem", producedASchema->u)],
        ~consumed=[("DeleteHandler", consumedDanglingSchema->u), ("BadTypeView", consumedBadTypeSchema->u)],
      )
      switch result {
      | Error(errors) => expect(errors->Array.length)->toBeGreaterThanOrEqual(2)
      | Ok() => fail("Expected validation errors")
      }
    })
  })

  describe("validateCompositeReads (Issue 5)", () => {
    let check = slices =>
      Reventless.DcbValidation.validateCompositeReads(~slices, ~producedTagKeys)

    testSync("warns when a composite read's consumed type carries an extra tag", () => {
      let warnings = check([("RecordDemand", recordDemandCommandSchema->u, demandConsumedSchema->u)])
      // ProductDemandRevoked carries customerId beyond [productId, orderId] → missed.
      expect(warnings->Array.length)->toBe(1)
      let w = warnings->Array.getUnsafe(0)
      expect(w.sliceName)->toBe("RecordDemand")
      expect(w.message->String.includes("ProductDemandRevoked"))->toBe(true)
      expect(w.message->String.includes("customerId"))->toBe(true)
    })

    testSync("does not warn for an exact-match consumed type", () => {
      // ProductDemandRecorded carries exactly [productId, orderId] — read finds it.
      let warnings = check([("RecordDemand", recordDemandCommandSchema->u, demandConsumedSchema->u)])
      expect(warnings->Array.some(w => w.message->String.includes("ProductDemandRecorded")))->toBe(
        false,
      )
    })

    testSync("ignores single-tag commands (partition read, not composite)", () => {
      let warnings = check([("TouchDemand", touchDemandCommandSchema->u, demandConsumedSchema->u)])
      expect(warnings)->toEqual([])
    })

    testSync("ignores tagged-array commands (per-element OR, not composite)", () => {
      let warnings = check([("PlaceOrder", placeOrderCommandSchema->u, demandConsumedSchema->u)])
      expect(warnings)->toEqual([])
    })

    testSync("no warnings when nothing reads compositely", () => {
      expect(check([]))->toEqual([])
    })
  })

  describe("validateCrossPartitionScope (Issue 13)", () => {
    let check = producers => Reventless.DcbValidation.validateCrossPartitionScope(~producers)

    testSync("no warning when every carrier of a key agrees on cross-partition scope", () => {
      let warnings = check([
        ("Subscribe", subscribedCrossPartitionSchema->u),
        ("Unsubscribe", unsubscribedCrossPartitionSchema->u),
      ])
      expect(warnings)->toEqual([])
    })

    testSync("warns when one producer leaves a cross-partition key partition-scoped", () => {
      let warnings = check([
        ("Subscribe", subscribedCrossPartitionSchema->u),
        ("Flag", flaggedPartitionScopedSchema->u),
      ])
      // 'Flag' carries studentId but partition-scoped, while 'Subscribe' declares it
      // @crossPartition → scope mismatch.
      expect(warnings->Array.length)->toBe(1)
      let w = warnings->Array.getUnsafe(0)
      expect(w.sliceName)->toBe("Flag")
      expect(w.message->String.includes("studentId"))->toBe(true)
    })

    testSync("no warning when no key is cross-partition anywhere", () => {
      expect(check([("Flag", flaggedPartitionScopedSchema->u)]))->toEqual([])
    })
  })
})
