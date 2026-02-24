open Jest
open Expect

describe("DcbTag:", () => {
  describe("jsonValueToString", () => {
    test("converts string value", () =>
      expect(ReventlessSpec.DcbTag.jsonValueToString(JSON.String("hello")))->toBe("hello")
    )

    test("converts integer-like number", () =>
      expect(ReventlessSpec.DcbTag.jsonValueToString(JSON.Number(42.)))->toBe("42")
    )

    test("converts float number", () =>
      expect(ReventlessSpec.DcbTag.jsonValueToString(JSON.Number(3.14)))->toBe("3.14")
    )

    test("converts boolean true", () =>
      expect(ReventlessSpec.DcbTag.jsonValueToString(JSON.Boolean(true)))->toBe("true")
    )

    test("converts boolean false", () =>
      expect(ReventlessSpec.DcbTag.jsonValueToString(JSON.Boolean(false)))->toBe("false")
    )

    test("converts null", () =>
      expect(ReventlessSpec.DcbTag.jsonValueToString(JSON.Null))->toBe("null")
    )

    test("converts array via JSON.stringify", () =>
      expect(
        ReventlessSpec.DcbTag.jsonValueToString(JSON.Array([JSON.Number(1.), JSON.Number(2.)])),
      )->toBe("[1,2]")
    )
  })

  describe("isTagged", () => {
    test("returns true for ReventlessSpec.DcbTag.string schema", () =>
      expect(ReventlessSpec.DcbTag.isTagged(ReventlessSpec.DcbTag.string->ReventlessSpec.DcbTag.toUnknownSchema))->toBe(true)
    )

    test("returns true for ReventlessSpec.DcbTag.int schema", () =>
      expect(ReventlessSpec.DcbTag.isTagged(ReventlessSpec.DcbTag.int->ReventlessSpec.DcbTag.toUnknownSchema))->toBe(true)
    )

    test("returns false for plain S.string schema", () =>
      expect(ReventlessSpec.DcbTag.isTagged(S.string->ReventlessSpec.DcbTag.toUnknownSchema))->toBe(false)
    )
  })

  describe("extractTags from variant (Union) schema", () => {
    test("extracts itemId tag from ItemCreated", () =>
      expect(
        ReventlessSpec.DcbTag.extractTags(
          DcbFixtures.TestEventLogSpec.eventSchema,
          DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"}),
        ),
      )->toEqual([{ReventlessSpec.DcbTag.key: "itemId", value: "item-1"}])
    )

    test("extracts itemId tag from ItemRenamed", () =>
      expect(
        ReventlessSpec.DcbTag.extractTags(
          DcbFixtures.TestEventLogSpec.eventSchema,
          DcbFixtures.TestEventLogSpec.ItemRenamed({itemId: "item-2", newName: "Updated"}),
        ),
      )->toEqual([{ReventlessSpec.DcbTag.key: "itemId", value: "item-2"}])
    )

    test("extracts multiple tags from CountUpdated", () =>
      expect(
        ReventlessSpec.DcbTag.extractTags(
          DcbFixtures.TestEventLogSpec.eventSchema,
          DcbFixtures.TestEventLogSpec.CountUpdated({category: "electronics", amount: 42}),
        ),
      )->toEqual([
        {ReventlessSpec.DcbTag.key: "category", value: "electronics"},
        {key: "amount", value: "42"},
      ])
    )

    test("returns empty array for SimpleEvent (no payload)", () =>
      expect(
        ReventlessSpec.DcbTag.extractTags(DcbFixtures.TestEventLogSpec.eventSchema, DcbFixtures.TestEventLogSpec.SimpleEvent),
      )->toEqual([])
    )

    test("returns empty array for untagged PlainEvent", () =>
      expect(
        ReventlessSpec.DcbTag.extractTags(
          DcbFixtures.UntaggedEventSpec.eventSchema,
          DcbFixtures.UntaggedEventSpec.PlainEvent({name: "test", value: 1}),
        ),
      )->toEqual([])
    )

    test("returns empty array for untagged EmptyEvent", () =>
      expect(
        ReventlessSpec.DcbTag.extractTags(DcbFixtures.UntaggedEventSpec.eventSchema, DcbFixtures.UntaggedEventSpec.EmptyEvent),
      )->toEqual([])
    )
  })

  describe("extractTags from Object schema", () => {
    test("extracts tenantId tag from object record", () =>
      expect(
        ReventlessSpec.DcbTag.extractTags(DcbFixtures.objectEventSchema, {DcbFixtures.tenantId: "tenant-1", data: "test"}),
      )->toEqual([{ReventlessSpec.DcbTag.key: "tenantId", value: "tenant-1"}])
    )
  })

  describe("extractTags from command schema", () => {
    test("extracts itemId tag from CreateItem command", () =>
      expect(
        ReventlessSpec.DcbTag.extractTags(
          DcbFixtures.TestCommandSpec.commandSchema,
          DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"}),
        ),
      )->toEqual([{ReventlessSpec.DcbTag.key: "itemId", value: "item-1"}])
    )

    test("extracts itemId tag from RenameItem command", () =>
      expect(
        ReventlessSpec.DcbTag.extractTags(
          DcbFixtures.TestCommandSpec.commandSchema,
          DcbFixtures.TestCommandSpec.RenameItem({itemId: "item-3", newName: "New"}),
        ),
      )->toEqual([{ReventlessSpec.DcbTag.key: "itemId", value: "item-3"}])
    )
  })

  describe("extractTaggedFields from schema", () => {
    describe("Union (variant) schemas", () => {
      test("extracts all unique tagged field names from event schema", () =>
        expect(ReventlessSpec.DcbTag.extractTaggedFields(DcbFixtures.TestEventLogSpec.eventSchema))->toEqual([
          "amount",
          "category",
          "itemId",
        ])
      )

      test("extracts tagged field names from command schema", () =>
        expect(ReventlessSpec.DcbTag.extractTaggedFields(DcbFixtures.TestCommandSpec.commandSchema))->toEqual([
          "itemId",
        ])
      )

      test("returns empty array for untagged variant schema", () =>
        expect(ReventlessSpec.DcbTag.extractTaggedFields(DcbFixtures.UntaggedEventSpec.eventSchema))->toEqual([])
      )

      test("deduplicates field names across variants", () => {
        // TestEventLogSpec has:
        // - ItemCreated: itemId
        // - ItemRenamed: itemId
        // - CountUpdated: category, amount
        // Should return sorted unique: ["amount", "category", "itemId"]
        let fields = ReventlessSpec.DcbTag.extractTaggedFields(DcbFixtures.TestEventLogSpec.eventSchema)
        expect(fields)->toEqual(["amount", "category", "itemId"])
      })

      test("returns sorted field names", () => {
        let fields = ReventlessSpec.DcbTag.extractTaggedFields(DcbFixtures.TestEventLogSpec.eventSchema)
        let sorted = fields->Array.toSorted((a, b) => String.compare(a, b))
        // Verify alphabetical sorting - should already be sorted
        expect(fields)->toEqual(sorted)
      })
    })

    describe("Object (record) schemas", () => {
      test("extracts tagged field names from object schema", () =>
        expect(ReventlessSpec.DcbTag.extractTaggedFields(DcbFixtures.objectEventSchema))->toEqual(["tenantId"])
      )

      test("returns empty array for object with no tagged fields", () =>
        expect(ReventlessSpec.DcbTag.extractTaggedFields(DcbFixtures.plainRecordSchema))->toEqual([])
      )

      test("extracts multiple tagged fields from object schema", () =>
        expect(ReventlessSpec.DcbTag.extractTaggedFields(DcbFixtures.multiTagRecordSchema))->toEqual([
          "tenantId",
          "userId",
        ])
      )
    })

    describe("Edge cases", () => {
      test("handles variants with no payload (SimpleEvent)", () => {
        // TestEventLogSpec includes SimpleEvent which has no payload
        // Should still extract fields from other variants
        let fields = ReventlessSpec.DcbTag.extractTaggedFields(DcbFixtures.TestEventLogSpec.eventSchema)
        expect(fields->Array.length)->toBeGreaterThan(0)
      })

      test("handles schema with mix of tagged and untagged fields", () =>
        expect(ReventlessSpec.DcbTag.extractTaggedFields(DcbFixtures.mixedEventSchema))->toEqual(["id"])
      )

      test("handles empty schema gracefully", () =>
        expect(ReventlessSpec.DcbTag.extractTaggedFields(DcbFixtures.emptyVariantSchema))->toEqual([])
      )

      test("handles schema with int tags", () =>
        expect(ReventlessSpec.DcbTag.extractTaggedFields(DcbFixtures.intTagEventSchema))->toEqual(["count"])
      )
    })

    describe("Complex schemas", () => {
      test("extracts from schema with many variants and fields", () =>
        expect(ReventlessSpec.DcbTag.extractTaggedFields(DcbFixtures.complexEventSchema))->toEqual([
          "orderId",
          "paymentId",
          "trackingId",
          "userId",
        ])
      )

      test("handles variants with multiple tagged fields in same variant", () =>
        expect(ReventlessSpec.DcbTag.extractTaggedFields(DcbFixtures.multiFieldEventSchema))->toEqual([
          "sessionId",
          "tenantId",
          "userId",
        ])
      )
    })
  })
})
