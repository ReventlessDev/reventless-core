open JestGlobals
open ApiNoApiHelpers

// The exclusion has to survive a variant spread. Splicing copies a union's
// members, not its metadata, so an exclusion recorded only on the union vanishes
// on the way into the host — and the host publishes as a mutation and a
// subscription a command whose author marked it internal. No error, no warning.
//
// Built the way the PPX builds it (`markNoApiVariants` on a freshly made union),
// then spliced the way the compiler splices it (concatenating `anyOf`), so this
// exercises the real path rather than a hand-stamped stand-in.
let member = name =>
  S.object(o => {
    let _ = o.field("TAG", S.literal(name))
  })->S.castToUnknown

let sourceUnion =
  S.union([member("Public"), member("Internal")])->ReventlessInfra.Api.markNoApiVariants([
    "Internal",
  ])

let spliced = switch sourceUnion {
| AnyOf({anyOf}) => S.union(Array.concat([member("HostOwn")], anyOf))
| _ => sourceUnion
}

describe("a spread carries its exclusions", () => {
  testSync("the source union still reports its own exclusion", () =>
    expect(getExcludedVariants(sourceUnion)->Option.map(Set.toArray))->toEqual(Some(["Internal"]))
  )

  testSync("a host that splices the members inherits the exclusion", () =>
    expect(getExcludedVariants(spliced)->Option.map(Set.toArray))->toEqual(Some(["Internal"]))
  )

  // The failure this closes, stated as the thing it must not do: the spliced
  // internal variant must not appear among the host's callable fields.
  testSync("the spliced internal variant is filtered out of a host's fields", () =>
    expect(filterNoApiVariants(["HostOwn", "Public", "Internal"], spliced))->toEqual([
      "HostOwn",
      "Public",
    ])
  )

  testSync("nothing else is filtered", () =>
    expect(filterNoApiVariants(["HostOwn", "Public"], spliced))->toEqual(["HostOwn", "Public"])
  )
})

describe("ApiNoApiHelpers:", () => {
  testSync("isNoApi returns false for schema without noApi metadata", () => {
    let schema = S.string->S.castToUnknown
    expect(isNoApi(schema))->toBe(false)
  })

  testSync("isNoApi returns true for schema with noApi metadata set to true", () => {
    let schema = S.string->S.castToUnknown
    let schema' = schema->S.Metadata.set(~id=ReventlessInfra.Api.noApiId, true)
    expect(isNoApi(schema'))->toBe(true)
  })

  testSync("getExcludedVariants returns None for schema without noApiVariants metadata", () => {
    let schema = S.string->S.castToUnknown
    expect(getExcludedVariants(schema))->toBe(None)
  })

  testSync("getExcludedVariants returns Some with DeleteItem when set", () => {
    let schema = S.string->S.castToUnknown
    let excluded = Set.fromArray(["DeleteItem", "UpdateItem"])
    let schema' = schema->S.Metadata.set(~id=ReventlessInfra.Api.noApiVariantsId, excluded)
    let result = getExcludedVariants(schema')
    expect(result->Option.map(set => set->Set.has("DeleteItem"))->Option.getOr(false))->toBe(true)
  })

  testSync("filterNoApiVariants returns all field names when no variants are excluded", () => {
    let schema = S.string->S.castToUnknown
    let fieldNames = ["CreateItem", "DeleteItem", "UpdateItem"]
    let filtered = filterNoApiVariants(fieldNames, schema)
    expect(filtered)->toEqual(["CreateItem", "DeleteItem", "UpdateItem"])
  })

  testSync("filterNoApiVariants filters out excluded variants", () => {
    let schema = S.string->S.castToUnknown
    let excluded = Set.fromArray(["DeleteItem"])
    let schema' = schema->S.Metadata.set(~id=ReventlessInfra.Api.noApiVariantsId, excluded)
    let fieldNames = ["CreateItem", "DeleteItem", "UpdateItem"]
    let filtered = filterNoApiVariants(fieldNames, schema')
    expect(filtered)->toEqual(["CreateItem", "UpdateItem"])
  })

  testSync("filterNoApiVariants filters out multiple excluded variants", () => {
    let schema = S.string->S.castToUnknown
    let excluded = Set.fromArray(["DeleteItem", "UpdateItem"])
    let schema' = schema->S.Metadata.set(~id=ReventlessInfra.Api.noApiVariantsId, excluded)
    let fieldNames = ["CreateItem", "DeleteItem", "UpdateItem", "GetItem"]
    let filtered = filterNoApiVariants(fieldNames, schema')
    expect(filtered)->toEqual(["CreateItem", "GetItem"])
  })

  testSync("filterNoApiVariants returns empty array when all variants are excluded", () => {
    let schema = S.string->S.castToUnknown
    let excluded = Set.fromArray(["CreateItem", "DeleteItem", "UpdateItem"])
    let schema' = schema->S.Metadata.set(~id=ReventlessInfra.Api.noApiVariantsId, excluded)
    let fieldNames = ["CreateItem", "DeleteItem", "UpdateItem"]
    let filtered = filterNoApiVariants(fieldNames, schema')
    expect(filtered)->toEqual([])
  })
})
