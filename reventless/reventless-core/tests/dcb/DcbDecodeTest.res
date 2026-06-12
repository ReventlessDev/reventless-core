open JestGlobals

// Produced event schema (full shape with tags — represents what's in storage)
@schema
type event =
  | ItemCreated({itemId: @s.matches(Reventless.DcbTag.string) string, name: string})
  | ItemRenamed({itemId: @s.matches(Reventless.DcbTag.string) string, newName: string})
  | ItemArchived({itemId: @s.matches(Reventless.DcbTag.string) string})

// Consumed event — payload-less
@schema
type consumedPayloadLess =
  | ItemCreated
  | ItemArchived

// Consumed event — partial projection
@schema
type consumedPartial =
  | ItemCreated({itemId: string})
  | ItemRenamed({itemId: string})

// Consumed event — full shape (no tags)
@schema
type consumedFull =
  | ItemCreated({itemId: string, name: string})
  | ItemRenamed({itemId: string, newName: string})
  | ItemArchived({itemId: string})

describe("DcbDecode:", () => {
  describe("makeDecoder — payload-less", () => {
    let {Reventless.DcbDecode.decode: decode, eventTypes} =
      Reventless.DcbDecode.makeDecoder(consumedPayloadLessSchema)

    testSync("returns correct eventTypes", () => {
      let sorted = eventTypes->Array.toSorted(String.compare)
      expect(sorted)->toEqual(["ItemArchived", "ItemCreated"])
    })

    testSync("decodes ItemCreated as payload-less variant", () => {
      let result = decode(
        ~eventType="ItemCreated",
        ~data=Dict.fromArray([("itemId", JSON.String("i-1")), ("name", JSON.String("Test"))]),
      )
      let expected: option<consumedPayloadLess> = Some(ItemCreated)
      expect(result)->toEqual(expected)
    })

    testSync("decodes ItemArchived as payload-less variant", () => {
      let result = decode(
        ~eventType="ItemArchived",
        ~data=Dict.fromArray([("itemId", JSON.String("i-1"))]),
      )
      let expected: option<consumedPayloadLess> = Some(ItemArchived)
      expect(result)->toEqual(expected)
    })

    testSync("returns None for unknown event type", () => {
      let result = decode(
        ~eventType="ItemRenamed",
        ~data=Dict.fromArray([("itemId", JSON.String("i-1"))]),
      )
      expect(result)->toEqual(None)
    })
  })

  describe("makeDecoder — partial projection", () => {
    let {Reventless.DcbDecode.decode: decode} =
      Reventless.DcbDecode.makeDecoder(consumedPartialSchema)

    testSync("decodes ItemCreated with only itemId field", () => {
      let result = decode(
        ~eventType="ItemCreated",
        ~data=Dict.fromArray([("itemId", JSON.String("i-1")), ("name", JSON.String("Test"))]),
      )
      let expected: option<consumedPartial> = Some(ItemCreated({itemId: "i-1"}))
      expect(result)->toEqual(expected)
    })

    testSync("decodes ItemRenamed with only itemId field", () => {
      let result = decode(
        ~eventType="ItemRenamed",
        ~data=Dict.fromArray([("itemId", JSON.String("i-1")), ("newName", JSON.String("New"))]),
      )
      let expected: option<consumedPartial> = Some(ItemRenamed({itemId: "i-1"}))
      expect(result)->toEqual(expected)
    })

    testSync("returns None for unknown event type", () => {
      let result = decode(~eventType="ItemArchived", ~data=Dict.fromArray([]))
      expect(result)->toEqual(None)
    })
  })

  describe("makeDecoder — full shape", () => {
    let {Reventless.DcbDecode.decode: decode} =
      Reventless.DcbDecode.makeDecoder(consumedFullSchema)

    testSync("decodes ItemCreated with all fields", () => {
      let result = decode(
        ~eventType="ItemCreated",
        ~data=Dict.fromArray([("itemId", JSON.String("i-1")), ("name", JSON.String("Test"))]),
      )
      expect(result)->toEqual(Some(ItemCreated({itemId: "i-1", name: "Test"})))
    })

    testSync("decodes ItemRenamed with all fields", () => {
      let result = decode(
        ~eventType="ItemRenamed",
        ~data=Dict.fromArray([("itemId", JSON.String("i-1")), ("newName", JSON.String("New"))]),
      )
      expect(result)->toEqual(Some(ItemRenamed({itemId: "i-1", newName: "New"})))
    })

    testSync("decodes ItemArchived with all fields", () => {
      let result = decode(
        ~eventType="ItemArchived",
        ~data=Dict.fromArray([("itemId", JSON.String("i-1"))]),
      )
      expect(result)->toEqual(Some(ItemArchived({itemId: "i-1"})))
    })
  })
})
