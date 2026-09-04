open JestGlobals

// An absent *optional* and an absent *required* field both arrive as `undefined`; only
// the schema says which is which. A bare `option` compiles to a union admitting
// `undefined`, so leaving it absent is the derived answer — the same kind of answer
// `null` is for a `T | null` union. Guessing instead turns `None` into a `Some` of a
// value no writer ever wrote, and an enum or a record is where that guess lands: the
// arms below the guard would supply the enum's first variant or a zero-filled `{}`.

@schema
type healKind = Domain | Platform

@schema
type healInner = {a: string, b: int}

@schema
type healOptionals = {
  name: string,
  optStr: option<string>,
  optArr: option<array<string>>,
  optRec: option<healInner>,
  optEnum: option<healKind>,
}

@schema
type healRequired = {name: string, addedLater: string}

@schema
type healNullable = {
  name: string,
  nullRec: @s.matches(healInnerSchema->S.nullAsOption) option<healInner>,
}

describe("fillMissingDefaults absent-optional arm:", () => {
  testSync("every absent optional stays absent and decodes to None", () => {
    let fills = []
    let healed = Message.fillMissingDefaults(
      healOptionalsSchema,
      `{"name":"p"}`->JSON.parseOrThrow,
      fills,
    )
    let decoded = healed->Util_Sury.fromJson(healOptionalsSchema)
    expect(decoded.name)->toBe("p")
    expect(decoded.optStr->Option.isNone)->toBe(true)
    expect(decoded.optArr->Option.isNone)->toBe(true)
    expect(decoded.optRec->Option.isNone)->toBe(true)
    expect(decoded.optEnum->Option.isNone)->toBe(true)
    // Nothing was invented, so nothing is reported.
    expect(fills)->toEqual([])
  })

  testSync("a present optional record still heals a field added after it was written", () => {
    let fills = []
    let healed = Message.fillMissingDefaults(
      healOptionalsSchema,
      `{"name":"p","optRec":{"a":"x"}}`->JSON.parseOrThrow,
      fills,
    )
    let decoded = healed->Util_Sury.fromJson(healOptionalsSchema)
    expect(decoded.optRec)->toEqual(Some({a: "x", b: 0}))
    expect(fills)->toEqual([".optRec.b := 0"])
  })

  testSync("a missing required scalar is still filled and reported", () => {
    let fills = []
    let healed = Message.fillMissingDefaults(
      healRequiredSchema,
      `{"name":"p"}`->JSON.parseOrThrow,
      fills,
    )
    expect(healed->Util_Sury.fromJson(healRequiredSchema))->toEqual({name: "p", addedLater: ""})
    expect(fills)->toEqual([`.addedLater := ""`])
  })

  testSync("the `T | null` arm is untouched — absent still heals to null, not undefined", () => {
    let fills = []
    let healed = Message.fillMissingDefaults(
      healNullableSchema,
      `{"name":"p"}`->JSON.parseOrThrow,
      fills,
    )
    expect(healed->JSON.stringify)->toBe(`{"name":"p","nullRec":null}`)
    expect((healed->Util_Sury.fromJson(healNullableSchema)).nullRec->Option.isNone)->toBe(true)
    expect(fills)->toEqual([])
  })
})
