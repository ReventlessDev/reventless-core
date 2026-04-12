open Jest
open Expect

describe("DcbTag:", () => {
  describe("jsonValueToString", () => {
    test(
      "converts string value",
      () => expect(Reventless.DcbTag.jsonValueToString(JSON.String("hello")))->toBe("hello"),
    )

    test(
      "converts integer-like number",
      () => expect(Reventless.DcbTag.jsonValueToString(JSON.Number(42.)))->toBe("42"),
    )

    test(
      "converts float number",
      () => expect(Reventless.DcbTag.jsonValueToString(JSON.Number(3.14)))->toBe("3.14"),
    )

    test(
      "converts boolean true",
      () => expect(Reventless.DcbTag.jsonValueToString(JSON.Boolean(true)))->toBe("true"),
    )

    test(
      "converts boolean false",
      () => expect(Reventless.DcbTag.jsonValueToString(JSON.Boolean(false)))->toBe("false"),
    )

    test(
      "converts null",
      () => expect(Reventless.DcbTag.jsonValueToString(JSON.Null))->toBe("null"),
    )

    test(
      "converts array via JSON.stringify",
      () =>
        expect(
          Reventless.DcbTag.jsonValueToString(JSON.Array([JSON.Number(1.), JSON.Number(2.)])),
        )->toBe("[1,2]"),
    )
  })

  describe("isTagged", () => {
    test(
      "returns true for Reventless.DcbTag.string schema",
      () =>
        expect(
          Reventless.DcbTag.isTagged(Reventless.DcbTag.string->Reventless.DcbTag.toUnknownSchema),
        )->toBe(true),
    )

    test(
      "returns true for Reventless.DcbTag.int schema",
      () =>
        expect(
          Reventless.DcbTag.isTagged(Reventless.DcbTag.int->Reventless.DcbTag.toUnknownSchema),
        )->toBe(true),
    )

    test(
      "returns false for plain S.string schema",
      () =>
        expect(Reventless.DcbTag.isTagged(S.string->Reventless.DcbTag.toUnknownSchema))->toBe(
          false,
        ),
    )
  })

  describe("extractTags from variant (Union) schema", () => {
    test(
      "extracts itemId tag from ItemCreated",
      () =>
        expect(
          Reventless.DcbTag.extractTags(
            DcbFixtures.TestEventLogSpec.eventSchema,
            DcbFixtures.TestEventLogSpec.ItemCreated({itemId: "item-1", name: "Test"}),
          ),
        )->toEqual([{Reventless.DcbTag.key: "itemId", value: "item-1"}]),
    )

    test(
      "extracts itemId tag from ItemRenamed",
      () =>
        expect(
          Reventless.DcbTag.extractTags(
            DcbFixtures.TestEventLogSpec.eventSchema,
            DcbFixtures.TestEventLogSpec.ItemRenamed({itemId: "item-2", newName: "Updated"}),
          ),
        )->toEqual([{Reventless.DcbTag.key: "itemId", value: "item-2"}]),
    )

    test(
      "extracts multiple tags from CountUpdated",
      () =>
        expect(
          Reventless.DcbTag.extractTags(
            DcbFixtures.TestEventLogSpec.eventSchema,
            DcbFixtures.TestEventLogSpec.CountUpdated({category: "electronics", amount: 42}),
          ),
        )->toEqual([
          {Reventless.DcbTag.key: "category", value: "electronics"},
          {key: "amount", value: "42"},
        ]),
    )

    test(
      "returns empty array for SimpleEvent (no payload)",
      () =>
        expect(
          Reventless.DcbTag.extractTags(
            DcbFixtures.TestEventLogSpec.eventSchema,
            DcbFixtures.TestEventLogSpec.SimpleEvent,
          ),
        )->toEqual([]),
    )

    test(
      "returns empty array for untagged PlainEvent",
      () =>
        expect(
          Reventless.DcbTag.extractTags(
            DcbFixtures.UntaggedEventSpec.eventSchema,
            DcbFixtures.UntaggedEventSpec.PlainEvent({name: "test", value: 1}),
          ),
        )->toEqual([]),
    )

    test(
      "returns empty array for untagged EmptyEvent",
      () =>
        expect(
          Reventless.DcbTag.extractTags(
            DcbFixtures.UntaggedEventSpec.eventSchema,
            DcbFixtures.UntaggedEventSpec.EmptyEvent,
          ),
        )->toEqual([]),
    )
  })

  describe("extractTags from Object schema", () => {
    test(
      "extracts tenantId tag from object record",
      () =>
        expect(
          Reventless.DcbTag.extractTags(
            DcbFixtures.objectEventSchema,
            {DcbFixtures.tenantId: "tenant-1", data: "test"},
          ),
        )->toEqual([{Reventless.DcbTag.key: "tenantId", value: "tenant-1"}]),
    )
  })

  describe("extractTags from command schema", () => {
    test(
      "extracts itemId tag from CreateItem command",
      () =>
        expect(
          Reventless.DcbTag.extractTags(
            DcbFixtures.TestCommandSpec.commandSchema,
            DcbFixtures.TestCommandSpec.CreateItem({itemId: "item-1", name: "Test"}),
          ),
        )->toEqual([{Reventless.DcbTag.key: "itemId", value: "item-1"}]),
    )

    test(
      "extracts itemId tag from RenameItem command",
      () =>
        expect(
          Reventless.DcbTag.extractTags(
            DcbFixtures.TestCommandSpec.commandSchema,
            DcbFixtures.TestCommandSpec.RenameItem({itemId: "item-3", newName: "New"}),
          ),
        )->toEqual([{Reventless.DcbTag.key: "itemId", value: "item-3"}]),
    )
  })

  describe("extractTaggedFields from schema", () => {
    describe(
      "Union (variant) schemas",
      () => {
        test(
          "extracts all unique tagged field names from event schema",
          () =>
            expect(
              Reventless.DcbTag.extractTaggedFields(DcbFixtures.TestEventLogSpec.eventSchema),
            )->toEqual(["amount", "category", "itemId"]),
        )

        test(
          "extracts tagged field names from command schema",
          () =>
            expect(
              Reventless.DcbTag.extractTaggedFields(DcbFixtures.TestCommandSpec.commandSchema),
            )->toEqual(["itemId"]),
        )

        test(
          "returns empty array for untagged variant schema",
          () =>
            expect(
              Reventless.DcbTag.extractTaggedFields(DcbFixtures.UntaggedEventSpec.eventSchema),
            )->toEqual([]),
        )

        test(
          "deduplicates field names across variants",
          () => {
            // TestEventLogSpec has:
            // - ItemCreated: itemId
            // - ItemRenamed: itemId
            // - CountUpdated: category, amount
            // Should return sorted unique: ["amount", "category", "itemId"]
            let fields = Reventless.DcbTag.extractTaggedFields(
              DcbFixtures.TestEventLogSpec.eventSchema,
            )
            expect(fields)->toEqual(["amount", "category", "itemId"])
          },
        )

        test(
          "returns sorted field names",
          () => {
            let fields = Reventless.DcbTag.extractTaggedFields(
              DcbFixtures.TestEventLogSpec.eventSchema,
            )
            let sorted = fields->Array.toSorted((a, b) => String.compare(a, b))
            // Verify alphabetical sorting - should already be sorted
            expect(fields)->toEqual(sorted)
          },
        )
      },
    )

    describe(
      "Object (record) schemas",
      () => {
        test(
          "extracts tagged field names from object schema",
          () =>
            expect(Reventless.DcbTag.extractTaggedFields(DcbFixtures.objectEventSchema))->toEqual([
              "tenantId",
            ]),
        )

        test(
          "returns empty array for object with no tagged fields",
          () =>
            expect(
              Reventless.DcbTag.extractTaggedFields(DcbFixtures.plainRecordSchema),
            )->toEqual([]),
        )

        test(
          "extracts multiple tagged fields from object schema",
          () =>
            expect(
              Reventless.DcbTag.extractTaggedFields(DcbFixtures.multiTagRecordSchema),
            )->toEqual(["tenantId", "userId"]),
        )
      },
    )

    describe(
      "Edge cases",
      () => {
        test(
          "handles variants with no payload (SimpleEvent)",
          () => {
            // TestEventLogSpec includes SimpleEvent which has no payload
            // Should still extract fields from other variants
            let fields = Reventless.DcbTag.extractTaggedFields(
              DcbFixtures.TestEventLogSpec.eventSchema,
            )
            expect(fields->Array.length)->toBeGreaterThan(0)
          },
        )

        test(
          "handles schema with mix of tagged and untagged fields",
          () =>
            expect(Reventless.DcbTag.extractTaggedFields(DcbFixtures.mixedEventSchema))->toEqual([
              "id",
            ]),
        )

        test(
          "handles empty schema gracefully",
          () =>
            expect(
              Reventless.DcbTag.extractTaggedFields(DcbFixtures.emptyVariantSchema),
            )->toEqual([]),
        )

        test(
          "handles schema with int tags",
          () =>
            expect(Reventless.DcbTag.extractTaggedFields(DcbFixtures.intTagEventSchema))->toEqual([
              "count",
            ]),
        )
      },
    )

    describe(
      "isTaggedArray",
      () => {
        test(
          "returns true for array of tagged strings",
          () => {
            let schema = S.array(Reventless.DcbTag.string)->Reventless.DcbTag.toUnknownSchema
            expect(Reventless.DcbTag.isTaggedArray(schema))->toBe(true)
          },
        )

        test(
          "returns false for array of plain strings",
          () => {
            let schema = S.array(S.string)->Reventless.DcbTag.toUnknownSchema
            expect(Reventless.DcbTag.isTaggedArray(schema))->toBe(false)
          },
        )

        test(
          "returns false for tagged scalar",
          () =>
            expect(
              Reventless.DcbTag.isTaggedArray(
                Reventless.DcbTag.string->Reventless.DcbTag.toUnknownSchema,
              ),
            )->toBe(false),
        )

        test(
          "returns false for plain string",
          () =>
            expect(
              Reventless.DcbTag.isTaggedArray(S.string->Reventless.DcbTag.toUnknownSchema),
            )->toBe(false),
        )
      },
    )

    describe(
      "Complex schemas",
      () => {
        test(
          "extracts from schema with many variants and fields",
          () =>
            expect(Reventless.DcbTag.extractTaggedFields(DcbFixtures.complexEventSchema))->toEqual([
              "orderId",
              "paymentId",
              "trackingId",
              "userId",
            ]),
        )

        test(
          "handles variants with multiple tagged fields in same variant",
          () =>
            expect(
              Reventless.DcbTag.extractTaggedFields(DcbFixtures.multiFieldEventSchema),
            )->toEqual(["sessionId", "tenantId", "userId"]),
        )
      },
    )
  })

  describe("extractTagsExpanded (array expansion)", () => {
    test(
      "expands array tagged field into per-element tags",
      () =>
        expect(
          Reventless.DcbTag.extractTagsExpanded(
            DcbFixtures.crossEntityCommandSchema,
            DcbFixtures.PlaceOrder({
              orderId: "ord-1",
              customerId: "cust-1",
              productId: ["prod-1", "prod-2"],
            }),
          ),
        )->toEqual([
          {Reventless.DcbTag.key: "orderId", value: "ord-1"},
          {key: "productId", value: "prod-1"},
          {key: "productId", value: "prod-2"},
        ]),
    )

    test(
      "handles empty array tagged field",
      () =>
        expect(
          Reventless.DcbTag.extractTagsExpanded(
            DcbFixtures.crossEntityCommandSchema,
            DcbFixtures.PlaceOrder({orderId: "ord-1", customerId: "cust-1", productId: []}),
          ),
        )->toEqual([{Reventless.DcbTag.key: "orderId", value: "ord-1"}]),
    )

    test(
      "scalar tagged fields unchanged",
      () =>
        expect(
          Reventless.DcbTag.extractTagsExpanded(
            DcbFixtures.singleTagCommandSchema,
            DcbFixtures.CreateItem({itemId: "item-1", name: "Test"}),
          ),
        )->toEqual([{Reventless.DcbTag.key: "itemId", value: "item-1"}]),
    )
  })

  describe("extractCompositePartitionFields", () => {
    test(
      "extracts 3 fields from single-variant composite schema",
      () => {
        let fields = Reventless.DcbTag.extractCompositePartitionFields(
          DcbFixtures.compositeEventSchema,
        )
        expect(fields->Array.length)->toBe(3)->ignore
        expect(fields->Array.map(f => f.name))->toEqual(["environment", "platformName", "pluginName"])
      },
    )

    test(
      "fields are sorted by position",
      () => {
        let fields = Reventless.DcbTag.extractCompositePartitionFields(
          DcbFixtures.compositeEventSchema,
        )
        let positions = fields->Array.map(f => f.position)
        expect(positions)->toEqual([0, 1, 2])
      },
    )

    test(
      "extracts separator values",
      () => {
        let fields = Reventless.DcbTag.extractCompositePartitionFields(
          DcbFixtures.compositeEventCustomSepSchema,
        )
        expect(fields->Array.map(f => f.sep))->toEqual([":", "/", "/"])
      },
    )

    test(
      "deduplicates fields across variants",
      () => {
        let fields = Reventless.DcbTag.extractCompositePartitionFields(
          DcbFixtures.compositeMultiVariantSchema,
        )
        expect(fields->Array.length)->toBe(2)->ignore
        expect(fields->Array.map(f => f.name))->toEqual(["env", "name"])
      },
    )

    test(
      "returns empty for schema without composite fields",
      () => {
        let fields = Reventless.DcbTag.extractCompositePartitionFields(
          DcbFixtures.TestEventLogSpec.eventSchema,
        )
        expect(fields)->toEqual([])
      },
    )
  })

  describe("getCompositePartitionKeyValue", () => {
    test(
      "joins values with default separator",
      () => {
        let spec: Reventless.DcbTag.compositePartitionSpec = {
          keys: ["environment", "platformName", "pluginName"],
          seps: ["/", "/"],
        }
        let tags: array<Reventless.DcbTag.tag> = [
          {key: "environment", value: "prod"},
          {key: "platformName", value: "aws"},
          {key: "pluginName", value: "catalog"},
        ]
        expect(Reventless.DcbTag.getCompositePartitionKeyValue(tags, spec))->toBe(
          "prod/aws/catalog",
        )
      },
    )

    test(
      "joins values with mixed separators",
      () => {
        let spec: Reventless.DcbTag.compositePartitionSpec = {
          keys: ["tenantId", "region", "service"],
          seps: [":", "/"],
        }
        let tags: array<Reventless.DcbTag.tag> = [
          {key: "tenantId", value: "acme"},
          {key: "region", value: "eu-west-1"},
          {key: "service", value: "auth"},
        ]
        expect(Reventless.DcbTag.getCompositePartitionKeyValue(tags, spec))->toBe(
          "acme:eu-west-1/auth",
        )
      },
    )

    test(
      "uses empty string for missing tag values",
      () => {
        let spec: Reventless.DcbTag.compositePartitionSpec = {
          keys: ["a", "b"],
          seps: ["/"],
        }
        let tags: array<Reventless.DcbTag.tag> = [{key: "a", value: "x"}]
        expect(Reventless.DcbTag.getCompositePartitionKeyValue(tags, spec))->toBe("x/")
      },
    )

    test(
      "handles tags in different order than keys",
      () => {
        let spec: Reventless.DcbTag.compositePartitionSpec = {
          keys: ["a", "b", "c"],
          seps: ["/", "/"],
        }
        let tags: array<Reventless.DcbTag.tag> = [
          {key: "c", value: "3"},
          {key: "a", value: "1"},
          {key: "b", value: "2"},
        ]
        expect(Reventless.DcbTag.getCompositePartitionKeyValue(tags, spec))->toBe("1/2/3")
      },
    )
  })

  describe("derivePartitionTag", () => {
    let u = S.castToUnknown

    test(
      "returns Composite for schema with >= 2 composite fields",
      () => {
        let result = Reventless.DcbTag.derivePartitionTag([
          ("Sync", "test.res", DcbFixtures.compositeEventSchema->u),
        ])
        switch result {
        | Composite(spec) =>
          expect(spec.keys)->toEqual(["environment", "platformName", "pluginName"])->ignore
          expect(spec.seps)->toEqual(["/", "/"])
        | Simple(_) => fail("Expected Composite")
        }
      },
    )

    test(
      "returns Composite with custom separators",
      () => {
        let result = Reventless.DcbTag.derivePartitionTag([
          ("Config", "test.res", DcbFixtures.compositeEventCustomSepSchema->u),
        ])
        switch result {
        | Composite(spec) =>
          expect(spec.keys)->toEqual(["tenantId", "region", "service"])->ignore
          expect(spec.seps)->toEqual([":", "/"])
        | Simple(_) => fail("Expected Composite")
        }
      },
    )

    test(
      "returns Simple for schema with only @partitionTag",
      () => {
        let result = Reventless.DcbTag.derivePartitionTag([
          ("Order", "test.res", DcbFixtures.simplePartitionEventSchema->u),
        ])
        switch result {
        | Simple(pt) => expect(pt.key)->toBe("orderId")
        | Composite(_) => fail("Expected Simple")
        }
      },
    )

    test(
      "returns Simple for schema with single tagged field",
      () => {
        let result = Reventless.DcbTag.derivePartitionTag([
          ("Item", "test.res", DcbFixtures.singleTagCommandSchema->u),
        ])
        switch result {
        | Simple(pt) => expect(pt.key)->toBe("itemId")
        | Composite(_) => fail("Expected Simple")
        }
      },
    )

    test(
      "throws on mixed composite and simple partition strategy",
      () => {
        let threw = ref(false)
        try {
          let _ = Reventless.DcbTag.derivePartitionTag([
            ("Mixed", "test.res", DcbFixtures.mixedStrategyEventSchema->u),
          ])
        } catch {
        | JsExn(err) =>
          threw := true
          expect(
            JsExn.message(err)->Option.getOr("")->String.includes(
              "mixes @compositePartitionTag and @partitionTag",
            ),
          )->toBe(true)->ignore
        }
        expect(threw.contents)->toBe(true)
      },
    )

    test(
      "throws on single composite field (< 2)",
      () => {
        let threw = ref(false)
        try {
          let _ = Reventless.DcbTag.derivePartitionTag([
            ("Single", "test.res", DcbFixtures.singleCompositeEventSchema->u),
          ])
        } catch {
        | JsExn(err) =>
          threw := true
          expect(
            JsExn.message(err)->Option.getOr("")->String.includes("at least 2 annotated fields"),
          )->toBe(true)->ignore
        }
        expect(threw.contents)->toBe(true)
      },
    )
  })

  describe("isCompositePartitionMember", () => {
    test(
      "returns true for compositePartitionMember schema",
      () =>
        expect(
          Reventless.DcbTag.isCompositePartitionMember(
            Reventless.DcbTag.compositePartitionMember(~position=0)->Reventless.DcbTag.toUnknownSchema,
          ),
        )->toBe(true),
    )

    test(
      "returns false for plain DcbTag.string",
      () =>
        expect(
          Reventless.DcbTag.isCompositePartitionMember(
            Reventless.DcbTag.string->Reventless.DcbTag.toUnknownSchema,
          ),
        )->toBe(false),
    )

    test(
      "returns false for plain S.string",
      () =>
        expect(
          Reventless.DcbTag.isCompositePartitionMember(
            S.string->Reventless.DcbTag.toUnknownSchema,
          ),
        )->toBe(false),
    )
  })

  describe("buildQueryFromCommand", () => {
    let eventTypes = ["EventA", "EventB"]

    test(
      "scalar-only command produces single AND clause",
      () =>
        expect(
          Reventless.DcbTag.buildQueryFromCommand(
            ~eventTypes,
            ~schema=DcbFixtures.singleTagCommandSchema,
            ~value=DcbFixtures.CreateItem({itemId: "item-1", name: "Test"}),
          ),
        )->toEqual([
          {
            Reventless.DcbTag.eventTypes,
            tags: [{key: "itemId", value: "item-1"}],
          },
        ]),
    )

    test(
      "tagged array command produces per-element OR clauses",
      () =>
        expect(
          Reventless.DcbTag.buildQueryFromCommand(
            ~eventTypes,
            ~schema=DcbFixtures.crossEntityCommandSchema,
            ~value=DcbFixtures.PlaceOrder({
              orderId: "ord-1",
              customerId: "cust-1",
              productId: ["prod-1", "prod-2"],
            }),
          ),
        )->toEqual([
          {Reventless.DcbTag.eventTypes, tags: [{key: "orderId", value: "ord-1"}]},
          {eventTypes, tags: [{key: "productId", value: "prod-1"}]},
          {eventTypes, tags: [{key: "productId", value: "prod-2"}]},
        ]),
    )

    test(
      "tagged array with single element produces two OR clauses",
      () =>
        expect(
          Reventless.DcbTag.buildQueryFromCommand(
            ~eventTypes,
            ~schema=DcbFixtures.crossEntityCommandSchema,
            ~value=DcbFixtures.PlaceOrder({
              orderId: "ord-1",
              customerId: "cust-1",
              productId: ["prod-1"],
            }),
          ),
        )->toEqual([
          {Reventless.DcbTag.eventTypes, tags: [{key: "orderId", value: "ord-1"}]},
          {eventTypes, tags: [{key: "productId", value: "prod-1"}]},
        ]),
    )

    test(
      "tagged array with empty array produces single clause for scalar tag",
      () =>
        expect(
          Reventless.DcbTag.buildQueryFromCommand(
            ~eventTypes,
            ~schema=DcbFixtures.crossEntityCommandSchema,
            ~value=DcbFixtures.PlaceOrder({orderId: "ord-1", customerId: "cust-1", productId: []}),
          ),
        )->toEqual([{Reventless.DcbTag.eventTypes, tags: [{key: "orderId", value: "ord-1"}]}]),
    )

    test(
      "hasTaggedArrayFields detects tagged arrays",
      () => {
        expect(Reventless.DcbTag.hasTaggedArrayFields(DcbFixtures.crossEntityCommandSchema))->toBe(
          true,
        )
      },
    )

    test(
      "hasTaggedArrayFields returns false for scalar-only schemas",
      () => {
        expect(Reventless.DcbTag.hasTaggedArrayFields(DcbFixtures.singleTagCommandSchema))->toBe(
          false,
        )
      },
    )
  })
})
