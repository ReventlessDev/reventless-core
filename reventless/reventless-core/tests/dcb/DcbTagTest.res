open Jest
open Expect

describe("DcbTag:", () => {
  describe("jsonValueToString", () => {
    test("converts string value", () =>
      expect(Reventless.DcbTag.jsonValueToString(JSON.String("hello")))->toBe("hello")
    )

    test("converts integer-like number", () =>
      expect(Reventless.DcbTag.jsonValueToString(JSON.Number(42.)))->toBe("42")
    )

    test("converts float number", () =>
      expect(Reventless.DcbTag.jsonValueToString(JSON.Number(3.14)))->toBe("3.14")
    )

    test("converts boolean true", () =>
      expect(Reventless.DcbTag.jsonValueToString(JSON.Boolean(true)))->toBe("true")
    )

    test("converts boolean false", () =>
      expect(Reventless.DcbTag.jsonValueToString(JSON.Boolean(false)))->toBe("false")
    )

    test("converts null", () =>
      expect(Reventless.DcbTag.jsonValueToString(JSON.Null))->toBe("null")
    )

    test("converts array via JSON.stringify", () =>
      expect(
        Reventless.DcbTag.jsonValueToString(JSON.Array([JSON.Number(1.), JSON.Number(2.)])),
      )->toBe("[1,2]")
    )
  })

  describe("isTagged", () => {
    test("returns true for Reventless.DcbTag.string schema", () =>
      expect(Reventless.DcbTag.isTagged(Reventless.DcbTag.string->Reventless.DcbTag.toUnknownSchema))->toBe(true)
    )

    test("returns true for Reventless.DcbTag.int schema", () =>
      expect(Reventless.DcbTag.isTagged(Reventless.DcbTag.int->Reventless.DcbTag.toUnknownSchema))->toBe(true)
    )

    test("returns false for plain S.string schema", () =>
      expect(Reventless.DcbTag.isTagged(S.string->Reventless.DcbTag.toUnknownSchema))->toBe(false)
    )
  })

  describe("extractTags from variant (Union) schema", () => {
    test("extracts itemId tag from ItemCreated", () =>
      expect(
        Reventless.DcbTag.extractTags(
          DcbFixtures.TestEventLogSpec.eventSchema,
          DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"}),
        ),
      )->toEqual([{Reventless.DcbTag.key: "itemId", value: "item-1"}])
    )

    test("extracts itemId tag from ItemRenamed", () =>
      expect(
        Reventless.DcbTag.extractTags(
          DcbFixtures.TestEventLogSpec.eventSchema,
          DcbFixtures.TestEventLogSpec.ItemRenamed({itemId: "item-2", newName: "Updated"}),
        ),
      )->toEqual([{Reventless.DcbTag.key: "itemId", value: "item-2"}])
    )

    test("extracts multiple tags from CountUpdated", () =>
      expect(
        Reventless.DcbTag.extractTags(
          DcbFixtures.TestEventLogSpec.eventSchema,
          DcbFixtures.TestEventLogSpec.CountUpdated({category: "electronics", amount: 42}),
        ),
      )->toEqual([
        {Reventless.DcbTag.key: "category", value: "electronics"},
        {key: "amount", value: "42"},
      ])
    )

    test("returns empty array for SimpleEvent (no payload)", () =>
      expect(
        Reventless.DcbTag.extractTags(DcbFixtures.TestEventLogSpec.eventSchema, DcbFixtures.TestEventLogSpec.SimpleEvent),
      )->toEqual([])
    )

    test("returns empty array for untagged PlainEvent", () =>
      expect(
        Reventless.DcbTag.extractTags(
          DcbFixtures.UntaggedEventSpec.eventSchema,
          DcbFixtures.UntaggedEventSpec.PlainEvent({name: "test", value: 1}),
        ),
      )->toEqual([])
    )

    test("returns empty array for untagged EmptyEvent", () =>
      expect(
        Reventless.DcbTag.extractTags(DcbFixtures.UntaggedEventSpec.eventSchema, DcbFixtures.UntaggedEventSpec.EmptyEvent),
      )->toEqual([])
    )
  })

  describe("extractTags from Object schema", () => {
    test("extracts tenantId tag from object record", () =>
      expect(
        Reventless.DcbTag.extractTags(DcbFixtures.objectEventSchema, {DcbFixtures.tenantId: "tenant-1", data: "test"}),
      )->toEqual([{Reventless.DcbTag.key: "tenantId", value: "tenant-1"}])
    )
  })

  describe("extractTags from command schema", () => {
    test("extracts itemId tag from CreateItem command", () =>
      expect(
        Reventless.DcbTag.extractTags(
          DcbFixtures.TestCommandSpec.commandSchema,
          DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"}),
        ),
      )->toEqual([{Reventless.DcbTag.key: "itemId", value: "item-1"}])
    )

    test("extracts itemId tag from RenameItem command", () =>
      expect(
        Reventless.DcbTag.extractTags(
          DcbFixtures.TestCommandSpec.commandSchema,
          DcbFixtures.TestCommandSpec.RenameItem({itemId: "item-3", newName: "New"}),
        ),
      )->toEqual([{Reventless.DcbTag.key: "itemId", value: "item-3"}])
    )
  })

  describe("extractTaggedFields from schema", () => {
    describe("Union (variant) schemas", () => {
      test("extracts all unique tagged field names from event schema", () =>
        expect(Reventless.DcbTag.extractTaggedFields(DcbFixtures.TestEventLogSpec.eventSchema))->toEqual([
          "amount",
          "category",
          "itemId",
        ])
      )

      test("extracts tagged field names from command schema", () =>
        expect(Reventless.DcbTag.extractTaggedFields(DcbFixtures.TestCommandSpec.commandSchema))->toEqual([
          "itemId",
        ])
      )

      test("returns empty array for untagged variant schema", () =>
        expect(Reventless.DcbTag.extractTaggedFields(DcbFixtures.UntaggedEventSpec.eventSchema))->toEqual([])
      )

      test("deduplicates field names across variants", () => {
        // TestEventLogSpec has:
        // - ItemCreated: itemId
        // - ItemRenamed: itemId
        // - CountUpdated: category, amount
        // Should return sorted unique: ["amount", "category", "itemId"]
        let fields = Reventless.DcbTag.extractTaggedFields(DcbFixtures.TestEventLogSpec.eventSchema)
        expect(fields)->toEqual(["amount", "category", "itemId"])
      })

      test("returns sorted field names", () => {
        let fields = Reventless.DcbTag.extractTaggedFields(DcbFixtures.TestEventLogSpec.eventSchema)
        let sorted = fields->Array.toSorted((a, b) => String.compare(a, b))
        // Verify alphabetical sorting - should already be sorted
        expect(fields)->toEqual(sorted)
      })
    })

    describe("Object (record) schemas", () => {
      test("extracts tagged field names from object schema", () =>
        expect(Reventless.DcbTag.extractTaggedFields(DcbFixtures.objectEventSchema))->toEqual(["tenantId"])
      )

      test("returns empty array for object with no tagged fields", () =>
        expect(Reventless.DcbTag.extractTaggedFields(DcbFixtures.plainRecordSchema))->toEqual([])
      )

      test("extracts multiple tagged fields from object schema", () =>
        expect(Reventless.DcbTag.extractTaggedFields(DcbFixtures.multiTagRecordSchema))->toEqual([
          "tenantId",
          "userId",
        ])
      )
    })

    describe("Edge cases", () => {
      test("handles variants with no payload (SimpleEvent)", () => {
        // TestEventLogSpec includes SimpleEvent which has no payload
        // Should still extract fields from other variants
        let fields = Reventless.DcbTag.extractTaggedFields(DcbFixtures.TestEventLogSpec.eventSchema)
        expect(fields->Array.length)->toBeGreaterThan(0)
      })

      test("handles schema with mix of tagged and untagged fields", () =>
        expect(Reventless.DcbTag.extractTaggedFields(DcbFixtures.mixedEventSchema))->toEqual(["id"])
      )

      test("handles empty schema gracefully", () =>
        expect(Reventless.DcbTag.extractTaggedFields(DcbFixtures.emptyVariantSchema))->toEqual([])
      )

      test("handles schema with int tags", () =>
        expect(Reventless.DcbTag.extractTaggedFields(DcbFixtures.intTagEventSchema))->toEqual(["count"])
      )
    })

    describe("Complex schemas", () => {
      test("extracts from schema with many variants and fields", () =>
        expect(Reventless.DcbTag.extractTaggedFields(DcbFixtures.complexEventSchema))->toEqual([
          "orderId",
          "paymentId",
          "trackingId",
          "userId",
        ])
      )

      test("handles variants with multiple tagged fields in same variant", () =>
        expect(Reventless.DcbTag.extractTaggedFields(DcbFixtures.multiFieldEventSchema))->toEqual([
          "sessionId",
          "tenantId",
          "userId",
        ])
      )
    })
  })
})
