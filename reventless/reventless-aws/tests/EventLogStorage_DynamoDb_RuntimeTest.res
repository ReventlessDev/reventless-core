open TestHelpers

module Runtime = EventLogStorage_DynamoDb_Runtime

let table: Util_DynamoDb_Runtime.resolvedTable = {
  id: "test-table-id",
  name: "TestTable",
  arn: "arn:aws:dynamodb:eu-west-1:000000000000:table/TestTable",
  hashKey: "id",
}

describe("Runtime.append", () => {
  testAsync("rejects > 100 events with a clear error before any AWS call", async () => {
    let jsons = Array.fromInitializer(~length=101, i =>
      [("seq", i->Int.toString->JSON.Encode.string)]->Dict.fromArray->JSON.Encode.object
    )
    let result = await Runtime.append(table)(0, "test-id", jsons)
    switch result {
    | Error(msg) =>
      expect(msg->String.includes("max 100 events per command"))->toBe(true)
      expect(msg->String.includes("101"))->toBe(true)
    | Ok(_) => expect("expected Error, got Ok")->toBe("")
    }
  })
})
