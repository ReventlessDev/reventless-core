open JestGlobals

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
    | Error(ReventlessCore.EventLog.StorageFailure(msg)) =>
      expect(msg->String.includes("max 100 events per command"))->toBe(true)
      expect(msg->String.includes("101"))->toBe(true)
    | Error(Conflict) => expect("expected StorageFailure, got Conflict")->toBe("")
    | Ok(_) => expect("expected Error, got Ok")->toBe("")
    }
  })
})

describe("Runtime.buildTransactItems", () => {
  testSync("builds one Put per event with attribute_not_exists(#p) condition", () => {
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

  testSync("scales to 100 items (TransactWriteItems hard limit)", () => {
    let jsons = Array.fromInitializer(~length=100, mkJson)
    let items = Runtime.buildTransactItems(table.name, jsons)
    expect(items->Array.length)->toBe(100)
  })

  testSync("returns empty array for empty input", () => {
    let items = Runtime.buildTransactItems(table.name, [])
    expect(items->Array.length)->toBe(0)
  })
})

// ─── Aggregate snapshots (docs/plans/done/aggregate-snapshotting.md) ───

describe("Runtime.replayQueryInput", () => {
  testSync("default bounds cover exactly the zero-padded event range", () => {
    let input = Runtime.replayQueryInput(table.name, "agg-1")
    expect(input.tableName)->toBe("TestTable")
    expect(input.consistentRead)->toEqual(Some(true))
    expect(input.keyConditionExpression)->toEqual(Some("id=:id AND #p BETWEEN :from AND :to"))
    expect(input.expressionAttributeNames->Option.flatMap(Dict.get(_, "#p")))->toEqual(
      Some("position"),
    )
    let values = input.expressionAttributeValues->Option.getOr(Dict.make())
    expect(values->Dict.get(":from"))->toEqual(Some(JSON.Encode.string("000000000")))
    expect(values->Dict.get(":to"))->toEqual(Some(JSON.Encode.string("999999999")))
  })

  testSync("fromSeq narrows the lower bound to the padded position", () => {
    let input = Runtime.replayQueryInput(table.name, "agg-1", ~fromSeq=42)
    let values = input.expressionAttributeValues->Option.getOr(Dict.make())
    expect(values->Dict.get(":from"))->toEqual(Some(JSON.Encode.string("000000042")))
  })

  testSync("the snapshot sentinel sorts outside the event range", () => {
    // DynamoDB compares string range keys lexicographically; the BETWEEN upper
    // bound excludes the snapshot row because "S" > "9".
    expect(Runtime.snapshotPosition > Runtime.maxEventPosition)->toBe(true)
    // And every padded event position stays inside the bounds.
    expect(Runtime.padSeq(0) >= "000000000" && Runtime.padSeq(0) <= "999999999")->toBe(true)
    expect(Runtime.padSeq(999999999) <= "999999999")->toBe(true)
  })
})

describe("Runtime snapshot item codec", () => {
  let snap: ReventlessCore.EventLog.snapshot = {
    seqNr: 50,
    state: JSON.Encode.object(Dict.fromArray([("names", JSON.Encode.int(3))])),
    schemaHash: "abc123",
  }

  testSync("snapshotItem round-trips through decodeSnapshotItem", () => {
    let item = Runtime.snapshotItem("agg-1", snap)
    expect(Runtime.decodeSnapshotItem(item))->toEqual(Some(snap))
    // The item rides the reserved sort key.
    let d = item->JSON.Decode.object->Option.getOr(Dict.make())
    expect(d->Dict.get("position"))->toEqual(Some(JSON.Encode.string("SNAPSHOT")))
    expect(d->Dict.get("id"))->toEqual(Some(JSON.Encode.string("agg-1")))
  })

  testSync("decodeSnapshotItem rejects a malformed item", () => {
    let bad =
      [("id", JSON.Encode.string("agg-1")), ("seqNr", JSON.Encode.string("not-a-number"))]
      ->Dict.fromArray
      ->JSON.Encode.object
    expect(Runtime.decodeSnapshotItem(bad))->toEqual(None)
  })

  testSync("a snapshot row never reaches the event stream feed", () => {
    // The DynamoDB stream decoder drops rows without an `event` column (same
    // mechanism that filters DCB FENCE rows), so snapshot writes are invisible
    // to event collectors.
    let asDict =
      Runtime.snapshotItem("agg-1", snap)->JSON.Decode.object->Option.getOr(Dict.make())
    expect(Util_DynamoDbStream_Runtime.buildJsonEvent'(asDict))->toEqual(None)
  })
})
