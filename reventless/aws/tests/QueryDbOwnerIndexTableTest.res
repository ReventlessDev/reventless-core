// The table half of the index `@owner` derives. Both assertions are about the
// DynamoDB resource the deploy would submit, which is the only artifact that
// exists before one.

open JestGlobals

// `Pulumi.Input.make` is `%identity`, so the provider-facing shape can be read
// back as the ReScript value it wraps.
external unwrap: Pulumi.Input.t<'a> => 'a = "%identity"

let ownerIndex: Reventless.ReadModel.indexConfig = {
  index: "_owner",
  type_: "S",
  idField: "customerId",
  subIdField: "id",
  projectionType: ALL,
  derived: true,
}

describe("the derived owner index", () => {
  // Not KEYS_ONLY and not INCLUDE: the list door pushes the caller's filter, the
  // retirement predicate and `requireAttribute` down as FilterExpressions over
  // arbitrary columns, and a DynamoDB filter on a GSI may only name projected
  // attributes. A row read through a narrow projection also comes back missing
  // fields, which resolves a non-null SDL field to null.
  testSync("is provisioned projecting every attribute", () => {
    let gsis = QueryDbStorage_DynamoDb.globalSecondaryIndexes([ownerIndex])->unwrap
    expect(
      gsis->Array.map(g => {
        let g = g->unwrap
        (g.name, g.hashKey, g.rangeKey, g.projectionType)
      }),
    )->toEqual([("_owner", "customerId", Some("id"), PulumiAws.DynamoDb.Table.ALL)])
  })

  // Pulumi rejects a table that defines the same attribute twice, and the derived
  // index sorts on `id` — the table's own partition key — on any view with no
  // `@subId`. Undeduped, adding `@owner` to such a view fails the deploy outright.
  testSync("does not redeclare an attribute the table already has", () => {
    let names = QueryDbStorage_DynamoDb.attributes(None, [ownerIndex])->Array.map(a => a.name)
    expect(names)->toEqual(["id", "customerId"])
  })

  // The same collision one step out: an index that sorts on the table's sort key.
  testSync("dedupes against the table's own sort key too", () => {
    let names =
      QueryDbStorage_DynamoDb.attributes(
        Some("placedAt"),
        [{...ownerIndex, subIdField: "placedAt"}],
      )->Array.map(a => a.name)
    expect(names)->toEqual(["id", "placedAt", "customerId"])
  })
})
