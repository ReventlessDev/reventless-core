open Jest
open Expect

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

    test("returns correct eventTypes", () => {
      let sorted = eventTypes->Array.toSorted(String.compare)
      expect(sorted)->toEqual(["ItemArchived", "ItemCreated"])
    })

    test("decodes ItemCreated as payload-less variant", () => {
      let result = decode(
        ~eventType="ItemCreated",
        ~data=Dict.fromArray([("itemId", JSON.String("i-1")), ("name", JSON.String("Test"))]),
      )
      expect(result)->toEqual(Some(ItemCreated))
    })

    test("decodes ItemArchived as payload-less variant", () => {
      let result = decode(
        ~eventType="ItemArchived",
        ~data=Dict.fromArray([("itemId", JSON.String("i-1"))]),
      )
      expect(result)->toEqual(Some(ItemArchived))
    })

    test("returns None for unknown event type", () => {
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

    test("decodes ItemCreated with only itemId field", () => {
      let result = decode(
        ~eventType="ItemCreated",
        ~data=Dict.fromArray([("itemId", JSON.String("i-1")), ("name", JSON.String("Test"))]),
      )
      expect(result)->toEqual(Some(ItemCreated({itemId: "i-1"})))
    })

    test("decodes ItemRenamed with only itemId field", () => {
      let result = decode(
        ~eventType="ItemRenamed",
        ~data=Dict.fromArray([("itemId", JSON.String("i-1")), ("newName", JSON.String("New"))]),
      )
      expect(result)->toEqual(Some(ItemRenamed({itemId: "i-1"})))
    })

    test("returns None for unknown event type", () => {
      let result = decode(~eventType="ItemArchived", ~data=Dict.fromArray([]))
      expect(result)->toEqual(None)
    })
  })

  describe("makeDecoder — full shape", () => {
    let {Reventless.DcbDecode.decode: decode} =
      Reventless.DcbDecode.makeDecoder(consumedFullSchema)

    test("decodes ItemCreated with all fields", () => {
      let result = decode(
        ~eventType="ItemCreated",
        ~data=Dict.fromArray([("itemId", JSON.String("i-1")), ("name", JSON.String("Test"))]),
      )
      expect(result)->toEqual(Some(ItemCreated({itemId: "i-1", name: "Test"})))
    })

    test("decodes ItemRenamed with all fields", () => {
      let result = decode(
        ~eventType="ItemRenamed",
        ~data=Dict.fromArray([("itemId", JSON.String("i-1")), ("newName", JSON.String("New"))]),
      )
      expect(result)->toEqual(Some(ItemRenamed({itemId: "i-1", newName: "New"})))
    })

    test("decodes ItemArchived with all fields", () => {
      let result = decode(
        ~eventType="ItemArchived",
        ~data=Dict.fromArray([("itemId", JSON.String("i-1"))]),
      )
      expect(result)->toEqual(Some(ItemArchived({itemId: "i-1"})))
    })
  })
})
