// Round-trips `Resource.resourceInfo` (and the enclosing `Resource.t`) through
// sury JSON. The `StorageKeys` variant carries an `option<string>` sortKey. A
// plain `option` inside a union payload once failed sury's jsonable validation,
// so `reverseConvertToJsonOrThrow` threw for EVERY StorageKeys value; the bug was
// fixed upstream in 11.0.0-alpha.11 and the field is back on the default encoding.
// Previously only the `NoInfo` case was exercised; the `Some(sortKey)` AND `None`
// StorageKeys cases pin that it round-trips either way.

open JestGlobals

let roundTripInfo = (v: Resource.resourceInfo) => {
  let json = v->S.decodeOrThrow(~from=Resource.resourceInfoSchema, ~to=S.json)
  expect(json->S.parseOrThrow(~to=Resource.resourceInfoSchema))->toEqual(v)
}

describe("Resource.resourceInfo round-trip", () => {
  testSync("StorageKeys with a sort key (Some)", () =>
    roundTripInfo(StorageKeys({partitionKey: "pk", sortKey: Some("sk")}))
  )
  testSync("StorageKeys without a sort key (None)", () =>
    roundTripInfo(StorageKeys({partitionKey: "pk", sortKey: None}))
  )
  testSync("StreamSource", () => roundTripInfo(StreamSource({sourceUrn: "urn:x"})))
  testSync("ApiResolver", () =>
    roundTripInfo(ApiResolver({typeName: "Query", fieldName: "products"}))
  )
  testSync("NoInfo", () => roundTripInfo(NoInfo))
})

describe("Resource.t round-trip", () => {
  testSync("a full resource carrying a StorageKeys(Some) resourceInfo", () => {
    let original: Resource.t = {
      name: "OrdersTable",
      id: "orders-123",
      urn: "urn:pulumi:stack::proj::aws:dynamodb/table:Table::OrdersTable",
      resourceInfo: StorageKeys({partitionKey: "orderId", sortKey: Some("seq")}),
      service: "dynamodb",
      role: "table",
      region: "eu-west-1",
      resourceType: "aws:dynamodb/table:Table",
      configuration: Dict.fromArray([("billingMode", "PAY_PER_REQUEST")]),
      tags: Dict.fromArray([("env", "prod")]),
    }
    let json = original->S.decodeOrThrow(~from=Resource.schema, ~to=S.json)
    expect(json->S.parseOrThrow(~to=Resource.schema))->toEqual(original)
  })
})
