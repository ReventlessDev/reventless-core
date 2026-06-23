open JestGlobals

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
  testSync("formats the fence partition key", () => {
    expect(Runtime.fencePartitionKey(tag("orderId", "ord-1")))->toBe("fence#orderId:ord-1")
  })

  testSync("does not collide with event partition keys", () => {
    let fenceId = Runtime.fencePartitionKey(tag("orderId", "ord-1"))
    let eventId = "orderId:ord-1"
    expect(fenceId == eventId)->toBe(false)
  })
})

describe("Runtime.fenceKey", () => {
  testSync("returns key with id and FENCE sort key", () => {
    let key = Runtime.fenceKey(tag("orderId", "ord-1"))
    expect(key->Dict.get("id"))->toEqual(Some("fence#orderId:ord-1"->JSON.Encode.string))
    expect(key->Dict.get("position"))->toEqual(Some("FENCE"->JSON.Encode.string))
  })
})

describe("Runtime.collectQueryTags", () => {
  testSync("returns empty array for empty query", () => {
    expect(Runtime.collectQueryTags([]))->toEqual([])
  })

  testSync("returns empty array when no queryItem has tags", () => {
    let q: Reventless.DcbTag.query = [{eventTypes: ["Foo"]}]
    expect(Runtime.collectQueryTags(q))->toEqual([])
  })

  testSync("collects tags from a single queryItem", () => {
    let q: Reventless.DcbTag.query = [
      {tags: [tag("orderId", "o1"), tag("customerId", "c1")]},
    ]
    let result = Runtime.collectQueryTags(q)
    expect(result->Array.length)->toBe(2)
  })

  testSync("dedupes same tag value across queryItems", () => {
    let q: Reventless.DcbTag.query = [
      {tags: [tag("productId", "p1")]},
      {tags: [tag("productId", "p1")]},
      {tags: [tag("productId", "p2")]},
    ]
    let result = Runtime.collectQueryTags(q)
    expect(result->Array.length)->toBe(2)
  })

  testSync("ignores queryItems without tags but keeps others", () => {
    let q: Reventless.DcbTag.query = [
      {eventTypes: ["Foo"]},
      {tags: [tag("orderId", "o1")]},
    ]
    let result = Runtime.collectQueryTags(q)
    expect(result->Array.length)->toBe(1)
  })
})

describe("Runtime.collectEventTags", () => {
  testSync("returns empty array for no events", () => {
    expect(Runtime.collectEventTags([]))->toEqual([])
  })

  testSync("dedupes tag values across events", () => {
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
  testSync("after=Some: per-consumed-type OCC check, bumps only produced types", () => {
    // ChangeProductName: reads [ProductAdded, ProductNameChanged], produces
    // ProductNameChanged. The check must reference only those two types — never
    // pos#ProductPriceChanged (the Issue 4 fix) — and bump only the produced type.
    let update = Runtime.buildConditionalFenceUpdate(
      "TestTable",
      tag("productId", "p1"),
      ~consumedTypes=["ProductAdded", "ProductNameChanged"],
      ~producedTypes=["ProductNameChanged"],
      ~newPosition="100",
      ~after=Some("50"),
    )
    expect(update.conditionExpression)->toEqual(
      Some(
        "(attribute_not_exists(#c0) OR #c0 <= :after) AND (attribute_not_exists(#c1) OR #c1 <= :after)",
      ),
    )
    expect(update.updateExpression)->toBe("SET #p0 = :new")
    expect(update.expressionAttributeNames)->toEqual(
      Some(
        Dict.fromArray([
          ("#p0", "pos#ProductNameChanged"),
          ("#c0", "pos#ProductAdded"),
          ("#c1", "pos#ProductNameChanged"),
        ]),
      ),
    )
    expect(update.expressionAttributeValues->Option.flatMap(v => v->Dict.get(":after")))->toEqual(
      Some("50"->JSON.Encode.string),
    )
    expect(update.expressionAttributeValues->Option.flatMap(v => v->Dict.get(":new")))->toEqual(
      Some("100"->JSON.Encode.string),
    )
  })

  testSync("after=Some: a non-read type is never referenced in the condition", () => {
    let update = Runtime.buildConditionalFenceUpdate(
      "TestTable",
      tag("productId", "p1"),
      ~consumedTypes=["ProductAdded", "ProductNameChanged"],
      ~producedTypes=["ProductNameChanged"],
      ~newPosition="100",
      ~after=Some("50"),
    )
    let referenced =
      update.expressionAttributeNames->Option.getOr(Dict.make())->Dict.valuesToArray
    expect(referenced->Array.includes("pos#ProductPriceChanged"))->toBe(false)
  })

  testSync("after=None: folded create guard over consumed ∪ produced types", () => {
    let update = Runtime.buildConditionalFenceUpdate(
      "TestTable",
      tag("productId", "p1"),
      ~consumedTypes=["ProductAdded"],
      ~producedTypes=["ProductAdded"],
      ~newPosition="100",
      ~after=None,
    )
    // consumed ∪ produced dedups to [ProductAdded] → a single attribute_not_exists.
    expect(update.conditionExpression)->toEqual(Some("attribute_not_exists(#c0)"))
    expect(update.updateExpression)->toBe("SET #p0 = :new")
    expect(update.expressionAttributeValues->Option.flatMap(v => v->Dict.get(":after")))->toEqual(
      None,
    )
  })

  testSync("targets the fence sentinel item", () => {
    let update = Runtime.buildConditionalFenceUpdate(
      "TestTable",
      tag("orderId", "o1"),
      ~consumedTypes=["OrderPlaced"],
      ~producedTypes=["OrderPlaced"],
      ~newPosition="100",
      ~after=None,
    )
    expect(update.key->Dict.get("id"))->toEqual(Some("fence#orderId:o1"->JSON.Encode.string))
    expect(update.key->Dict.get("position"))->toEqual(Some("FENCE"->JSON.Encode.string))
  })
})

describe("Runtime.buildUnconditionalFenceUpdate", () => {
  testSync("does not set a conditionExpression", () => {
    let update = Runtime.buildUnconditionalFenceUpdate(
      "TestTable",
      tag("orderId", "o1"),
      ~producedTypes=["OrderPlaced"],
      ~newPosition="100",
    )
    expect(update.conditionExpression)->toEqual(None)
  })

  testSync("bumps each produced type's position attribute", () => {
    let update = Runtime.buildUnconditionalFenceUpdate(
      "TestTable",
      tag("orderId", "o1"),
      ~producedTypes=["OrderPlaced", "OrderShipped"],
      ~newPosition="100",
    )
    expect(update.updateExpression)->toBe("SET #p0 = :new, #p1 = :new")
    expect(update.expressionAttributeNames)->toEqual(
      Some(Dict.fromArray([("#p0", "pos#OrderPlaced"), ("#p1", "pos#OrderShipped")])),
    )
  })
})

describe("Runtime.buildQueryByPartitionKeyInput", () => {
  testSync("omits consistentRead by default (eventually consistent)", () => {
    let input = Runtime.buildQueryByPartitionKeyInput(table, "orderId:o1")
    expect(input.consistentRead)->toEqual(None)
  })

  testSync("omits consistentRead when ~strongConsistency=false", () => {
    let input = Runtime.buildQueryByPartitionKeyInput(
      table,
      "orderId:o1",
      ~strongConsistency=false,
    )
    expect(input.consistentRead)->toEqual(None)
  })

  testSync("sets consistentRead=true when ~strongConsistency=true", () => {
    let input = Runtime.buildQueryByPartitionKeyInput(
      table,
      "orderId:o1",
      ~strongConsistency=true,
    )
    expect(input.consistentRead)->toEqual(Some(true))
  })

  testSync("does not target a GSI (uses base table)", () => {
    let input = Runtime.buildQueryByPartitionKeyInput(
      table,
      "orderId:o1",
      ~strongConsistency=true,
    )
    expect(input.indexName)->toEqual(None)
  })

  testSync("threads ~after into the key condition without dropping consistentRead", () => {
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

describe("Runtime.buildScanFilter — excludes fence sentinels (Issue 12)", () => {
  testSync("tagless, type-less scan still guards against fence# items", () => {
    let filter = Runtime.buildScanFilter()
    // No event-type disjunction, but the fence guard is always present, so
    // `fence#…` sentinels (which lack the `event` attribute) are never returned.
    expect(filter.filterExpression)->toEqual(Some("attribute_exists(#evt)"))
    expect(filter.expressionAttributeNames)->toEqual(Some(Dict.fromArray([("#evt", "event")])))
    expect(filter.expressionAttributeValues)->toEqual(None)
  })

  testSync("an empty event-type list yields only the fence guard, not a degenerate ()", () => {
    let filter = Runtime.buildScanFilter(~eventTypes=[])
    expect(filter.filterExpression)->toEqual(Some("attribute_exists(#evt)"))
    expect(filter.expressionAttributeValues)->toEqual(None)
  })

  testSync("an event-type filter is AND-ed after the fence guard", () => {
    let filter = Runtime.buildScanFilter(~eventTypes=["OrderPlaced", "OrderShipped"])
    expect(filter.filterExpression)->toEqual(
      Some("attribute_exists(#evt) AND (#evt = :type0 OR #evt = :type1)"),
    )
    expect(filter.expressionAttributeValues)->toEqual(
      Some(
        Dict.fromArray([
          (":type0", "OrderPlaced"->JSON.Encode.string),
          (":type1", "OrderShipped"->JSON.Encode.string),
        ]),
      ),
    )
  })
})

describe("Runtime.buildEventPuts", () => {
  let event = (eventType, tags): ReventlessCore.DcbEventLog_Adapter.rawStoredEvent => {
    eventType,
    data: JSON.Object(Dict.make()),
    tags,
    meta: testMeta(),
  }

  testSync("emits one Put per event with the table name", () => {
    let puts = Runtime.buildEventPuts(
      table,
      [event("Created", [tag("orderId", "o1")]), event("Shipped", [tag("orderId", "o1")])],
      "100",
    )
    expect(puts->Array.length)->toBe(2)
    let first = puts->Array.getUnsafe(0)
    expect(first.put->Option.map(p => p.tableName))->toEqual(Some("TestTable"))
  })

  testSync("returns no Puts when events is empty", () => {
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

describe("Runtime.buildConditionalTransactItems — fence-scope = read-scope", () => {
  let event = (eventType, tags): ReventlessCore.DcbEventLog_Adapter.rawStoredEvent => {
    eventType,
    data: JSON.Object(Dict.make()),
    tags,
    meta: testMeta(),
  }

  // Locate the fence transact item (Update or ConditionCheck) targeting `fenceId`.
  let findFence = (items: array<AwsSdk.DynamoDb.DocumentClient.TransactWriteCommand.transactWriteItem>, fenceId) =>
    items->Array.find(it => {
      let idOf = key => key->Dict.get("id") == Some(fenceId->JSON.Encode.string)
      switch (it.update, it.conditionCheck) {
      | (Some(u), _) => idOf(u.key)
      | (_, Some(c)) => idOf(c.key)
      | _ => false
      }
    })
  let isUpdate = it => it->Option.flatMap(i => i.AwsSdk.DynamoDb.DocumentClient.TransactWriteCommand.update)->Option.isSome
  let isCheck = it => it->Option.flatMap(i => i.AwsSdk.DynamoDb.DocumentClient.TransactWriteCommand.conditionCheck)->Option.isSome

  describe("PlaceOrder shape: OrderPlaced partitioned by orderId, reads orderId + productId", () => {
    let orderPlaced = event(
      "OrderPlaced",
      [tag("orderId", "o1"), tag("customerId", "c1"), tag("productId", "p5")],
    )
    let partitionTag = Some(Reventless.DcbTag.Simple({key: "orderId"}))
    let cond: Reventless.DcbTag.appendCondition = {
      query: [
        {tags: [tag("orderId", "o1")], eventTypes: ["OrderPlaced"]},
        {tags: [tag("productId", "p5")], eventTypes: ["OrderPlaced", "CatalogProductSynced"]},
      ],
      after: "50",
    }
    let items = Runtime.buildConditionalTransactItems(table, [orderPlaced], cond, "100", ~partitionTag?)

    testSync("partition tag (orderId) is a conditional Update that bumps the fence", () => {
      expect(isUpdate(findFence(items, "fence#orderId:o1")))->toBe(true)
    })

    testSync("non-partition read tag (productId) is a ConditionCheck, not a bump", () => {
      let it = findFence(items, "fence#productId:p5")
      expect(isCheck(it))->toBe(true)
      expect(isUpdate(it))->toBe(false)
    })

    testSync("secondary event tag (customerId) is not fenced at all", () => {
      expect(findFence(items, "fence#customerId:c1")->Option.isSome)->toBe(false)
    })
  })

  describe("composite (multi-tag) read keeps check+bump on all its tags", () => {
    // RecordProductDemand-style: one multi-tag clause => composite GSI read.
    let demand = event("ProductDemandRecorded", [tag("productId", "p1"), tag("orderId", "o1")])
    let partitionTag = Some(Reventless.DcbTag.Simple({key: "productId"}))
    let cond: Reventless.DcbTag.appendCondition = {
      query: [
        {tags: [tag("productId", "p1"), tag("orderId", "o1")], eventTypes: ["ProductDemandRecorded"]},
      ],
      after: "50",
    }
    let items = Runtime.buildConditionalTransactItems(table, [demand], cond, "100", ~partitionTag?)

    testSync("partition tag (productId) is a conditional Update", () => {
      expect(isUpdate(findFence(items, "fence#productId:p1")))->toBe(true)
    })

    testSync("other composite tag (orderId) is also a conditional Update — OCC preserved", () => {
      expect(isUpdate(findFence(items, "fence#orderId:o1")))->toBe(true)
    })
  })

  // Cross-partition tag: fence bumped by every carrier (Issue 13 / Phase 7).
  // StudentSubscribed partitions by courseId; studentId is @crossPartition, so a
  // single-tag studentId read crosses partitions and its fence must move on every
  // carrier — even though studentId is a *secondary* tag here. After fan-out the
  // M:N command yields two single-tag clauses.
  describe("cross-partition secondary tag (studentId) is check+bump, not read-only", () => {
    let subscribed = event("StudentSubscribed", [tag("courseId", "C1"), tag("studentId", "S1")])
    let partitionTag = Some(Reventless.DcbTag.Simple({key: "courseId"}))
    let cond: Reventless.DcbTag.appendCondition = {
      query: [
        {tags: [tag("courseId", "C1")], eventTypes: ["StudentSubscribed"]},
        {tags: [tag("studentId", "S1")], eventTypes: ["StudentSubscribed"]},
      ],
      after: "50",
    }

    testSync("with studentId cross-partition, its fence is a conditional Update (bump)", () => {
      let items = Runtime.buildConditionalTransactItems(
        table,
        [subscribed],
        cond,
        "100",
        ~partitionTag?,
        ~crossPartitionTagKeys=["studentId"],
      )
      // courseId (partition) bumps as usual; studentId (cross-partition secondary) also bumps.
      expect(isUpdate(findFence(items, "fence#courseId:C1")))->toBe(true)
      expect(isUpdate(findFence(items, "fence#studentId:S1")))->toBe(true)
    })

    testSync("without the cross-partition flag, studentId is only a read-only ConditionCheck", () => {
      let items = Runtime.buildConditionalTransactItems(table, [subscribed], cond, "100", ~partitionTag?)
      let it = findFence(items, "fence#studentId:S1")
      expect(isCheck(it))->toBe(true)
      expect(isUpdate(it))->toBe(false)
    })
  })
})

describe("Runtime.buildConditionalTransactItems — folded create guard (after=None)", () => {
  let event = (eventType, tags): ReventlessCore.DcbEventLog_Adapter.rawStoredEvent => {
    eventType,
    data: JSON.Object(Dict.make()),
    tags,
    meta: testMeta(),
  }

  // The partition-tag fence Update for `fenceId`, if any.
  let fenceUpdate = (
    items: array<AwsSdk.DynamoDb.DocumentClient.TransactWriteCommand.transactWriteItem>,
    fenceId,
  ) =>
    items->Array.findMap(it =>
      switch it.AwsSdk.DynamoDb.DocumentClient.TransactWriteCommand.update {
      | Some(u) if u.key->Dict.get("id") == Some(fenceId->JSON.Encode.string) => Some(u)
      | _ => None
      }
    )

  // True if any item targets a legacy `create#…` sentinel row (must be none now).
  let hasCreateRow = (items: array<AwsSdk.DynamoDb.DocumentClient.TransactWriteCommand.transactWriteItem>) =>
    items->Array.some(it =>
      switch it.AwsSdk.DynamoDb.DocumentClient.TransactWriteCommand.update {
      | Some(u) =>
        u.key
        ->Dict.get("id")
        ->Option.flatMap(JSON.Decode.string)
        ->Option.mapOr(false, id => id->String.startsWith("create#"))
      | None => false
      }
    )

  let referencedAttrs = (u: AwsSdk.DynamoDb.DocumentClient.TransactWriteCommand.update) =>
    u.expressionAttributeNames->Option.getOr(Dict.make())->Dict.valuesToArray

  describe("first write of a create slice (consumes == produces)", () => {
    let added = event("ProductAdded", [tag("productId", "p1")])
    let partitionTag = Some(Reventless.DcbTag.Simple({key: "productId"}))
    let cond: Reventless.DcbTag.appendCondition = {
      query: [{tags: [tag("productId", "p1")], eventTypes: ["ProductAdded"]}],
    }
    let items = Runtime.buildConditionalTransactItems(table, [added], cond, "100", ~partitionTag?)

    testSync("no separate create# row is emitted (guard folded into the fence)", () => {
      expect(hasCreateRow(items))->toBe(false)
    })

    testSync("the partition fence is a conditional Update gated on attribute_not_exists", () => {
      let u = fenceUpdate(items, "fence#productId:p1")->Option.getOrThrow
      expect(u.conditionExpression)->toEqual(Some("attribute_not_exists(#c0)"))
      expect(u.updateExpression)->toBe("SET #p0 = :new")
      expect(u.expressionAttributeValues->Option.flatMap(v => v->Dict.get(":after")))->toEqual(None)
    })

    testSync("the guard references only the produced/consumed type", () => {
      let u = fenceUpdate(items, "fence#productId:p1")->Option.getOrThrow
      let referenced = referencedAttrs(u)
      expect(referenced->Array.includes("pos#ProductAdded"))->toBe(true)
      expect(referenced->Array.includes("pos#ProductPriceChanged"))->toBe(false)
    })
  })

  describe("produced-not-consumed (the double-create gate — analysis con #1)", () => {
    // A slice producing a type it does NOT read must still guard on the produced
    // type at after=None, or two concurrent first-writers both commit.
    let started = event("OrderStarted", [tag("orderId", "o1")])
    let partitionTag = Some(Reventless.DcbTag.Simple({key: "orderId"}))
    let cond: Reventless.DcbTag.appendCondition = {
      query: [{tags: [tag("orderId", "o1")], eventTypes: ["OrderDrafted"]}],
    }
    let items = Runtime.buildConditionalTransactItems(table, [started], cond, "100", ~partitionTag?)

    testSync("the produced type is in the guard even though it is not consumed", () => {
      let u = fenceUpdate(items, "fence#orderId:o1")->Option.getOrThrow
      let referenced = referencedAttrs(u)
      // guard set = consumed ∪ produced = {OrderDrafted, OrderStarted}
      expect(referenced->Array.includes("pos#OrderStarted"))->toBe(true)
      expect(referenced->Array.includes("pos#OrderDrafted"))->toBe(true)
    })

    testSync("the bump advances the produced type", () => {
      let u = fenceUpdate(items, "fence#orderId:o1")->Option.getOrThrow
      expect(u.updateExpression)->toBe("SET #p0 = :new")
      expect(u.expressionAttributeNames->Option.flatMap(n => n->Dict.get("#p0")))->toEqual(
        Some("pos#OrderStarted"),
      )
    })
  })

  describe("at after=Some (entity exists)", () => {
    let changed = event("ProductNameChanged", [tag("productId", "p1")])
    let partitionTag = Some(Reventless.DcbTag.Simple({key: "productId"}))
    let cond: Reventless.DcbTag.appendCondition = {
      query: [
        {tags: [tag("productId", "p1")], eventTypes: ["ProductAdded", "ProductNameChanged"]},
      ],
      after: "50",
    }
    let items = Runtime.buildConditionalTransactItems(table, [changed], cond, "100", ~partitionTag?)

    testSync("emits no create# row", () => {
      expect(hasCreateRow(items))->toBe(false)
    })

    testSync("the fence check covers consumed types but not unrelated ones (Issue 4 fix)", () => {
      let u = fenceUpdate(items, "fence#productId:p1")->Option.getOrThrow
      let referenced = referencedAttrs(u)
      expect(referenced->Array.includes("pos#ProductAdded"))->toBe(true)
      expect(referenced->Array.includes("pos#ProductNameChanged"))->toBe(true)
      expect(referenced->Array.includes("pos#ProductPriceChanged"))->toBe(false)
    })
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
    // 100 unique single-tag query clauses + 1 event = 101 items, over the limit.
    // `after` is set so each clause yields a conditional fence item (Update for the
    // partition tag, ConditionCheck for the rest) rather than the idempotent
    // bump-only fallback.
    let manyTags = Array.fromInitializer(~length=100, i => tag("k", `v${i->Int.toString}`))
    let cond: Reventless.DcbTag.appendCondition = {
      query: manyTags->Array.map(t => {Reventless.DcbTag.tags: [t], eventTypes: ["Foo"]}),
      after: "0",
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

// Phase 3: the deploy-time `make` provisions `tag_composite` with a full (ALL)
// projection and every per-tag `tag_<key>` GSI as KEYS_ONLY. This guards the
// pure predicate that drives that decision (the Pulumi wiring itself is
// type-checked by the build, not unit-tested).
describe("Runtime.indexKeepsFullProjection", () => {
  testSync("tag_composite keeps a full projection", () => {
    expect(Runtime.indexKeepsFullProjection("tag_composite"))->toBe(true)
  })
  testSync("per-tag GSIs are KEYS_ONLY (no full projection)", () => {
    expect(Runtime.indexKeepsFullProjection("tag_orderId"))->toBe(false)
    expect(Runtime.indexKeepsFullProjection("tag_customerId"))->toBe(false)
    expect(Runtime.indexKeepsFullProjection("tag_productId"))->toBe(false)
  })
})
