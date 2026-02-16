open Jest
open Expect

describe("DcbTag:", () => {
  describe("jsonValueToString", () => {
    test("converts string value", () =>
      expect(DcbTag.jsonValueToString(JSON.String("hello")))->toBe("hello")
    )

    test("converts integer-like number", () =>
      expect(DcbTag.jsonValueToString(JSON.Number(42.)))->toBe("42")
    )

    test("converts float number", () =>
      expect(DcbTag.jsonValueToString(JSON.Number(3.14)))->toBe("3.14")
    )

    test("converts boolean true", () =>
      expect(DcbTag.jsonValueToString(JSON.Boolean(true)))->toBe("true")
    )

    test("converts boolean false", () =>
      expect(DcbTag.jsonValueToString(JSON.Boolean(false)))->toBe("false")
    )

    test("converts null", () =>
      expect(DcbTag.jsonValueToString(JSON.Null))->toBe("null")
    )

    test("converts array via JSON.stringify", () =>
      expect(
        DcbTag.jsonValueToString(JSON.Array([JSON.Number(1.), JSON.Number(2.)])),
      )->toBe("[1,2]")
    )
  })

  describe("isTagged", () => {
    test("returns true for DcbTag.string schema", () =>
      expect(DcbTag.isTagged(DcbTag.string->DcbTag.toUnknownSchema))->toBe(true)
    )

    test("returns true for DcbTag.int schema", () =>
      expect(DcbTag.isTagged(DcbTag.int->DcbTag.toUnknownSchema))->toBe(true)
    )

    test("returns false for plain S.string schema", () =>
      expect(DcbTag.isTagged(S.string->DcbTag.toUnknownSchema))->toBe(false)
    )
  })

  describe("extractTags from variant (Union) schema", () => {
    test("extracts itemId tag from ItemCreated", () =>
      expect(
        DcbTag.extractTags(
          DcbFixtures.TestEventLogSpec.eventSchema,
          DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"}),
        ),
      )->toEqual([{DcbTag.key: "itemId", value: "item-1"}])
    )

    test("extracts itemId tag from ItemRenamed", () =>
      expect(
        DcbTag.extractTags(
          DcbFixtures.TestEventLogSpec.eventSchema,
          DcbFixtures.TestEventLogSpec.ItemRenamed({itemId: "item-2", newName: "Updated"}),
        ),
      )->toEqual([{DcbTag.key: "itemId", value: "item-2"}])
    )

    test("extracts multiple tags from CountUpdated", () =>
      expect(
        DcbTag.extractTags(
          DcbFixtures.TestEventLogSpec.eventSchema,
          DcbFixtures.TestEventLogSpec.CountUpdated({category: "electronics", amount: 42}),
        ),
      )->toEqual([
        {DcbTag.key: "category", value: "electronics"},
        {key: "amount", value: "42"},
      ])
    )

    test("returns empty array for SimpleEvent (no payload)", () =>
      expect(
        DcbTag.extractTags(DcbFixtures.TestEventLogSpec.eventSchema, DcbFixtures.TestEventLogSpec.SimpleEvent),
      )->toEqual([])
    )

    test("returns empty array for untagged PlainEvent", () =>
      expect(
        DcbTag.extractTags(
          DcbFixtures.UntaggedEventSpec.eventSchema,
          DcbFixtures.UntaggedEventSpec.PlainEvent({name: "test", value: 1}),
        ),
      )->toEqual([])
    )

    test("returns empty array for untagged EmptyEvent", () =>
      expect(
        DcbTag.extractTags(DcbFixtures.UntaggedEventSpec.eventSchema, DcbFixtures.UntaggedEventSpec.EmptyEvent),
      )->toEqual([])
    )
  })

  describe("extractTags from Object schema", () => {
    test("extracts tenantId tag from object record", () =>
      expect(
        DcbTag.extractTags(DcbFixtures.objectEventSchema, {DcbFixtures.tenantId: "tenant-1", data: "test"}),
      )->toEqual([{DcbTag.key: "tenantId", value: "tenant-1"}])
    )
  })

  describe("extractTags from command schema", () => {
    test("extracts itemId tag from CreateItem command", () =>
      expect(
        DcbTag.extractTags(
          DcbFixtures.TestCommandSpec.commandSchema,
          DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"}),
        ),
      )->toEqual([{DcbTag.key: "itemId", value: "item-1"}])
    )

    test("extracts itemId tag from RenameItem command", () =>
      expect(
        DcbTag.extractTags(
          DcbFixtures.TestCommandSpec.commandSchema,
          DcbFixtures.TestCommandSpec.RenameItem({itemId: "item-3", newName: "New"}),
        ),
      )->toEqual([{DcbTag.key: "itemId", value: "item-3"}])
    )
  })
})
