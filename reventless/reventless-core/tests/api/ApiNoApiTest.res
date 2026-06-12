open JestGlobals
open ApiNoApiHelpers

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
