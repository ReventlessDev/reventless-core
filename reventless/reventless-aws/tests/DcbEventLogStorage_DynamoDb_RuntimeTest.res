open TestHelpers

module Runtime = DcbEventLogStorage_DynamoDb_Runtime

let tag = (key, value): Reventless.DcbTag.tag => {key, value}

let testMeta = () => ReventlessCore.Message.generateMeta(~service="test")

let table: Util_DynamoDb_Runtime.resolvedTable = {
  id: "test-table-id",
  name: "TestTable",
  arn: "arn:aws:dynamodb:eu-west-1:000000000000:table/TestTable",
  hashKey: "id",
}

describe("Runtime.fencePartitionKey", () => {
  test("formats the fence partition key", () => {
    expect(Runtime.fencePartitionKey(tag("orderId", "ord-1")))->toBe("fence#orderId:ord-1")
  })

  test("does not collide with event partition keys", () => {
    let fenceId = Runtime.fencePartitionKey(tag("orderId", "ord-1"))
    let eventId = "orderId:ord-1"
    expect(fenceId == eventId)->toBe(false)
  })
})

describe("Runtime.fenceKey", () => {
  test("returns key with id and FENCE sort key", () => {
    let key = Runtime.fenceKey(tag("orderId", "ord-1"))
    expect(key->Dict.get("id"))->toEqual(Some("fence#orderId:ord-1"->JSON.Encode.string))
    expect(key->Dict.get("position"))->toEqual(Some("FENCE"->JSON.Encode.string))
  })
})

describe("Runtime.collectQueryTags", () => {
  test("returns empty array for empty query", () => {
    expect(Runtime.collectQueryTags([]))->toEqual([])
  })

  test("returns empty array when no queryItem has tags", () => {
    let q: Reventless.DcbTag.query = [{eventTypes: ["Foo"]}]
    expect(Runtime.collectQueryTags(q))->toEqual([])
  })

  test("collects tags from a single queryItem", () => {
    let q: Reventless.DcbTag.query = [
      {tags: [tag("orderId", "o1"), tag("customerId", "c1")]},
    ]
    let result = Runtime.collectQueryTags(q)
    expect(result->Array.length)->toBe(2)
  })

  test("dedupes same tag value across queryItems", () => {
    let q: Reventless.DcbTag.query = [
      {tags: [tag("productId", "p1")]},
      {tags: [tag("productId", "p1")]},
      {tags: [tag("productId", "p2")]},
    ]
    let result = Runtime.collectQueryTags(q)
    expect(result->Array.length)->toBe(2)
  })

  test("ignores queryItems without tags but keeps others", () => {
    let q: Reventless.DcbTag.query = [
      {eventTypes: ["Foo"]},
      {tags: [tag("orderId", "o1")]},
    ]
    let result = Runtime.collectQueryTags(q)
    expect(result->Array.length)->toBe(1)
  })
})

describe("Runtime.collectEventTags", () => {
  test("returns empty array for no events", () => {
    expect(Runtime.collectEventTags([]))->toEqual([])
  })

  test("dedupes tag values across events", () => {
    let event1: ReventlessCore.DcbEventLog_Adapter.rawStoredEvent = {
      eventType: "ProductAdded",
      data: JSON.Object(Dict.make()),
      tags: [tag("productId", "p1"), tag("categoryId", "c1")],
      meta: testMeta(),
    }
    let event2: ReventlessCore.DcbEventLog_Adapter.rawStoredEvent = {
      eventType: "ProductAdded",
      data: JSON.Object(Dict.make()),
      tags: [tag("productId", "p1"), tag("categoryId", "c2")],
      meta: testMeta(),
    }
    let result = Runtime.collectEventTags([event1, event2])
    expect(result->Array.length)->toBe(3)
  })
})

describe("Runtime.buildConditionalFenceUpdate", () => {
  test("uses attribute_not_exists when after is None", () => {
    let update = Runtime.buildConditionalFenceUpdate(
      "TestTable",
      tag("orderId", "o1"),
      ~newPosition="100",
      ~after=None,
    )
    expect(update.conditionExpression)->toEqual(Some("attribute_not_exists(lastPosition)"))
  })

  test("includes lastPosition <= :after when after is Some", () => {
    let update = Runtime.buildConditionalFenceUpdate(
      "TestTable",
      tag("orderId", "o1"),
      ~newPosition="100",
      ~after=Some("50"),
    )
    expect(update.conditionExpression)->toEqual(
      Some("attribute_not_exists(lastPosition) OR lastPosition <= :after"),
    )
    expect(update.expressionAttributeValues->Option.flatMap(v => v->Dict.get(":after")))->toEqual(
      Some("50"->JSON.Encode.string),
    )
  })

  test("always sets lastPosition to newPosition", () => {
    let update = Runtime.buildConditionalFenceUpdate(
      "TestTable",
      tag("orderId", "o1"),
      ~newPosition="100",
      ~after=None,
    )
    expect(update.updateExpression)->toBe("SET lastPosition = :new")
    expect(update.expressionAttributeValues->Option.flatMap(v => v->Dict.get(":new")))->toEqual(
      Some("100"->JSON.Encode.string),
    )
  })

  test("targets the fence sentinel item", () => {
    let update = Runtime.buildConditionalFenceUpdate(
      "TestTable",
      tag("orderId", "o1"),
      ~newPosition="100",
      ~after=None,
    )
    expect(update.key->Dict.get("id"))->toEqual(Some("fence#orderId:o1"->JSON.Encode.string))
    expect(update.key->Dict.get("position"))->toEqual(Some("FENCE"->JSON.Encode.string))
  })
})

describe("Runtime.buildUnconditionalFenceUpdate", () => {
  test("does not set a conditionExpression", () => {
    let update = Runtime.buildUnconditionalFenceUpdate(
      "TestTable",
      tag("orderId", "o1"),
      ~newPosition="100",
    )
    expect(update.conditionExpression)->toEqual(None)
  })

  test("still bumps lastPosition", () => {
    let update = Runtime.buildUnconditionalFenceUpdate(
      "TestTable",
      tag("orderId", "o1"),
      ~newPosition="100",
    )
    expect(update.updateExpression)->toBe("SET lastPosition = :new")
  })
})

describe("Runtime.buildQueryByPartitionKeyInput", () => {
  test("omits consistentRead by default (eventually consistent)", () => {
    let input = Runtime.buildQueryByPartitionKeyInput(table, "orderId:o1")
    expect(input.consistentRead)->toEqual(None)
  })

  test("omits consistentRead when ~strongConsistency=false", () => {
    let input = Runtime.buildQueryByPartitionKeyInput(
      table,
      "orderId:o1",
      ~strongConsistency=false,
    )
    expect(input.consistentRead)->toEqual(None)
  })

  test("sets consistentRead=true when ~strongConsistency=true", () => {
    let input = Runtime.buildQueryByPartitionKeyInput(
      table,
      "orderId:o1",
      ~strongConsistency=true,
    )
    expect(input.consistentRead)->toEqual(Some(true))
  })

  test("does not target a GSI (uses base table)", () => {
    let input = Runtime.buildQueryByPartitionKeyInput(
      table,
      "orderId:o1",
      ~strongConsistency=true,
    )
    expect(input.indexName)->toEqual(None)
  })

  test("threads ~after into the key condition without dropping consistentRead", () => {
    let input = Runtime.buildQueryByPartitionKeyInput(
      table,
      "orderId:o1",
      ~after="50",
      ~strongConsistency=true,
    )
    expect(input.consistentRead)->toEqual(Some(true))
    expect(input.keyConditionExpression)->toEqual(Some("id = :pk AND #pos > :after"))
  })
})

describe("Runtime.buildEventPuts", () => {
  let event = (eventType, tags): ReventlessCore.DcbEventLog_Adapter.rawStoredEvent => {
    eventType,
    data: JSON.Object(Dict.make()),
    tags,
    meta: testMeta(),
  }

  test("emits one Put per event with the table name", () => {
    let puts = Runtime.buildEventPuts(
      table,
      [event("Created", [tag("orderId", "o1")]), event("Shipped", [tag("orderId", "o1")])],
      "100",
    )
    expect(puts->Array.length)->toBe(2)
    let first = puts->Array.getUnsafe(0)
    expect(first.put->Option.map(p => p.tableName))->toEqual(Some("TestTable"))
  })

  test("returns no Puts when events is empty", () => {
    let puts = Runtime.buildEventPuts(table, [], "100")
    expect(puts->Array.length)->toBe(0)
  })
})

describe("Runtime.appendUnconditional", () => {
  let event = (eventType, tags): ReventlessCore.DcbEventLog_Adapter.rawStoredEvent => {
    eventType,
    data: JSON.Object(Dict.make()),
    tags,
    meta: testMeta(),
  }

  testAsync("rejects appends exceeding 100 items with a clear error", async () => {
    // 100 distinct tag values across events → 100 fence bumps + 1 event = 101 items.
    let manyTags = Array.fromInitializer(~length=100, i => tag("k", `v${i->Int.toString}`))
    let events = manyTags->Array.map(t => event("Foo", [t]))
    let result = await Runtime.appendUnconditional(table, events)
    switch result {
    | Error(msg) => expect(msg->String.includes("limit exceeded"))->toBe(true)
    | Ok(_) => expect("expected Error, got Ok")->toBe("")
    }
  })
})

describe("Runtime.appendConditional", () => {
  testAsync("rejects tagless conditions with a clear error", async () => {
    let cond: Reventless.DcbTag.appendCondition = {
      query: [{eventTypes: ["Foo"]}],
    }
    let result = await Runtime.appendConditional(table, [], cond)
    switch result {
    | Error(msg) =>
      expect(msg->String.includes("tagless"))->toBe(true)
    | Ok(_) => expect("expected Error, got Ok")->toBe("")
    }
  })

  testAsync("rejects appends exceeding 100 items with a clear error", async () => {
    // 100 unique tag values + 1 event = 101 items, over the limit.
    let manyTags = Array.fromInitializer(~length=100, i => tag("k", `v${i->Int.toString}`))
    let cond: Reventless.DcbTag.appendCondition = {
      query: manyTags->Array.map(t => {Reventless.DcbTag.tags: [t]}),
    }
    let event: ReventlessCore.DcbEventLog_Adapter.rawStoredEvent = {
      eventType: "Foo",
      data: JSON.Object(Dict.make()),
      tags: [tag("k", "v0")],
      meta: testMeta(),
    }
    let result = await Runtime.appendConditional(table, [event], cond)
    switch result {
    | Error(msg) =>
      expect(msg->String.includes("limit exceeded"))->toBe(true)
    | Ok(_) => expect("expected Error, got Ok")->toBe("")
    }
  })
})
