open TestHelpers

module Runtime = EventLogStorage_DynamoDb_Runtime

let table: Util_DynamoDb_Runtime.resolvedTable = {
  id: "test-table-id",
  name: "TestTable",
  arn: "arn:aws:dynamodb:eu-west-1:000000000000:table/TestTable",
  hashKey: "id",
}

let mkJson = i =>
  [("position", i->Int.toString->JSON.Encode.string)]->Dict.fromArray->JSON.Encode.object

describe("Runtime.append", () => {
  testAsync("rejects > 100 events with a clear error before any AWS call", async () => {
    let jsons = Array.fromInitializer(~length=101, mkJson)
    let result = await Runtime.append(table)(0, "test-id", jsons)
    switch result {
    | Error(msg) =>
      expect(msg->String.includes("max 100 events per command"))->toBe(true)
      expect(msg->String.includes("101"))->toBe(true)
    | Ok(_) => expect("expected Error, got Ok")->toBe("")
    }
  })
})

describe("Runtime.buildTransactItems", () => {
  test("builds one Put per event with attribute_not_exists(#p) condition", () => {
    let jsons = Array.fromInitializer(~length=2, mkJson)
    let items = Runtime.buildTransactItems(table.name, jsons)
    expect(items->Array.length)->toBe(2)
    let first = items->Array.getUnsafe(0)
    switch first.put {
    | Some(p) =>
      expect(p.tableName)->toBe("TestTable")
      // `position` is a DynamoDB reserved keyword; the runtime references it
      // via the `#p` placeholder declared in expressionAttributeNames.
      expect(p.conditionExpression)->toEqual(Some("attribute_not_exists(#p)"))
      expect(p.expressionAttributeNames->Option.flatMap(Dict.get(_, "#p")))->toEqual(
        Some("position"),
      )
    | None => expect("expected Put, got None")->toBe("")
    }
  })

  test("scales to 100 items (TransactWriteItems hard limit)", () => {
    let jsons = Array.fromInitializer(~length=100, mkJson)
    let items = Runtime.buildTransactItems(table.name, jsons)
    expect(items->Array.length)->toBe(100)
  })

  test("returns empty array for empty input", () => {
    let items = Runtime.buildTransactItems(table.name, [])
    expect(items->Array.length)->toBe(0)
  })
})
