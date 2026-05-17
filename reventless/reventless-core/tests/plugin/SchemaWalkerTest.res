open Jest
open Expect


@schema
type simpleRecord = {
  label: string,
  count: int,
  rating?: float,
}

@schema
type simpleVariant =
  | Added({id: string, name: string})
  | Renamed({id: string, newName: string})
  | Removed

describe("SchemaWalker:", () => {
  describe("record schema", () => {
    let result = SchemaWalker.walk("SimpleRecord", simpleRecordSchema)

    test("kind is record", () => expect(result.kind)->toBe("record"))
    test("constructors is absent", () => expect(result.constructors)->toEqual(None))

    test("fields are sorted alphabetically", () => {
      let names = result.fields->Array.map(f => f.name)
      expect(names)->toEqual(["count", "label", "rating"])
    })

    test("required string field", () => {
      let f = result.fields->Array.getUnsafe(1)
      expect((f.typeDescription, f.isRequired))->toEqual(("string", true))
    })

    test("required int field typeDescription is number", () => {
      let f = result.fields->Array.getUnsafe(0)
      expect((f.typeDescription, f.isRequired))->toEqual(("number", true))
    })

    test("optional float field", () => {
      let f = result.fields->Array.getUnsafe(2)
      expect((f.typeDescription, f.isRequired))->toEqual(("option<number>", false))
    })

    test("structuralHash is non-empty", () =>
      expect(result.structuralHash->String.length > 0)->toBe(true)
    )
  })

  describe("variant schema", () => {
    let result = SchemaWalker.walk("SimpleVariant", simpleVariantSchema)

    test("kind is variant", () => expect(result.kind)->toBe("variant"))
    test("fields array is empty", () => expect(result.fields)->toEqual([]))

    test("payload-less constructor Removed is excluded", () => {
      let ctors = result.constructors->Option.getOr([])
      let names = ctors->Array.map(c => c.name)->Array.toSorted(String.compare)
      expect(names)->toEqual(["Added", "Renamed"])
    })

    test("Added constructor has sorted fields", () => {
      let ctors = result.constructors->Option.getOr([])
      let added = ctors->Array.find(c => c.name == "Added")->Option.getOr({Plugin_BuiltHook.name: "", fields: []})
      expect(added.fields->Array.map(f => f.name))->toEqual(["id", "name"])
    })

    test("Renamed constructor has sorted fields", () => {
      let ctors = result.constructors->Option.getOr([])
      let renamed = ctors->Array.find(c => c.name == "Renamed")->Option.getOr({Plugin_BuiltHook.name: "", fields: []})
      expect(renamed.fields->Array.map(f => f.name))->toEqual(["id", "newName"])
    })

    test("structuralHash is non-empty", () =>
      expect(result.structuralHash->String.length > 0)->toBe(true)
    )
  })

  describe("hash properties", () => {
    test("same schema produces identical hash on repeated calls", () => {
      let h1 = SchemaWalker.walk("X", simpleRecordSchema).structuralHash
      let h2 = SchemaWalker.walk("X", simpleRecordSchema).structuralHash
      expect(h1)->toBe(h2)
    })

    test("typeName does not affect structuralHash", () => {
      let h1 = SchemaWalker.walk("TypeA", simpleRecordSchema).structuralHash
      let h2 = SchemaWalker.walk("TypeB", simpleRecordSchema).structuralHash
      expect(h1)->toBe(h2)
    })

    test("structurally distinct schemas produce different hashes", () => {
      let h1 = SchemaWalker.walk("R", simpleRecordSchema).structuralHash
      let h2 = SchemaWalker.walk("V", simpleVariantSchema).structuralHash
      expect(h1 == h2)->toBe(false)
    })
  })

  describe("scalar / unsupported schema", () => {
    test("plain string schema → kind unknown", () => {
      let result = SchemaWalker.walk("Scalar", S.string)
      expect(result.kind)->toBe("unknown")
    })

    test("plain string schema → empty fields", () => {
      let result = SchemaWalker.walk("Scalar", S.string)
      expect(result.fields)->toEqual([])
    })

    test("plain string schema → empty structuralHash", () => {
      let result = SchemaWalker.walk("Scalar", S.string)
      expect(result.structuralHash)->toBe("")
    })
  })
})
