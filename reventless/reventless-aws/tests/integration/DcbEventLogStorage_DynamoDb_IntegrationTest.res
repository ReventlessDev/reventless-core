// DCB DynamoDB integration suite — exercises the real fence path against a
// DynamoDB Local engine (NOT run by the default unit suite; see
// `jest.integration.config.js` + `scripts/run-integration-tests.sh`).
//
// The unit suite (`DcbEventLogStorage_DynamoDb_RuntimeTest.res`) asserts the
// *shape* of the built `TransactWriteItems`. This suite asserts DynamoDB's
// *behaviour* — that the `ConditionExpression`s interpret as we expect — which
// is the only thing that proves the fence-scope model (Issue 1 fix) and the
// optimistic-concurrency guarantees end-to-end. See
// `docs/analysis/dcb-consistency-check-issues.md` and
// `docs/plans/dcb-consistency-hardening.md` (Phase 1).

open JestGlobals

module H = DcbIntegrationHarness
module Runtime = DcbEventLogStorage_DynamoDb_Runtime

let tag = (key, value): Reventless.DcbTag.tag => {key, value}
let meta = () => ReventlessCore.Message.generateMeta(~service="dcb-it")

let event = (eventType, tags): ReventlessCore.DcbEventLog_Adapter.rawStoredEvent => {
  eventType,
  data: JSON.Object(Dict.make()),
  tags,
  meta: meta(),
}

let simple = (key): Reventless.DcbTag.derivedPartitionTag => Simple({key: key})

let isOk = r =>
  switch r {
  | Ok(_) => true
  | Error(_) => false
  }

let isConflict = r =>
  switch r {
  | Error(msg) => msg->String.includes("Conflict")
  | Ok(_) => false
  }

// Read a slice's decision-model head position for a query — the `after` an
// append rides with.
let readAfter = async (table, query: Reventless.DcbTag.query) => {
  let result = await Runtime.read(table)(~query)
  result.headPosition
}

// Seed a single event with no consistency check (import/replay path). Bumps the
// event's partition fence so later conditional readers observe it.
let seed = (table, ev, ~partitionTag) => Runtime.appendUnconditional(table, [ev], ~partitionTag)

describe("DCB DynamoDb integration — fence-scope = read-scope (Issue 1 regression)", () => {
  let productTag = tag("productId", "P5")

  // Place an order: read (orderId ∪ productId), then append OrderPlaced.
  let placeOrder = async (table, ~orderId, ~customerId) => {
    let query: Reventless.DcbTag.query = [
      {tags: [tag("orderId", orderId)]},
      {tags: [productTag]},
    ]
    let after = await readAfter(table, query)
    await Runtime.appendConditional(
      table,
      [event("OrderPlaced", [tag("orderId", orderId), tag("customerId", customerId), productTag])],
      {query, after: ?after},
      ~partitionTag=simple("orderId"),
    )
  }

  testAsync("a second order of the same product (different order + customer) succeeds", async () => {
    let table = await H.freshTable()
    let _ = await seed(table, event("CatalogProductSynced", [productTag]), ~partitionTag=simple("productId"))

    let r1 = await placeOrder(table, ~orderId="O1", ~customerId="C1")
    let r2 = await placeOrder(table, ~orderId="O2", ~customerId="C2")

    expect(isOk(r1))->toBe(true)
    expect(isOk(r2))->toBe(true)
  })

  testAsync("two concurrent orders of the same product both succeed (no productId contention)", async () => {
    let table = await H.freshTable()
    let _ = await seed(table, event("CatalogProductSynced", [productTag]), ~partitionTag=simple("productId"))

    let results = await Promise.all([
      placeOrder(table, ~orderId="OA", ~customerId="CA"),
      placeOrder(table, ~orderId="OB", ~customerId="CB"),
    ])

    expect(results->Array.every(isOk))->toBe(true)
  })

  testAsync("a concurrent product re-sync after the order's read still conflicts (OCC preserved)", async () => {
    let table = await H.freshTable()
    let _ = await seed(table, event("CatalogProductSynced", [productTag]), ~partitionTag=simple("productId"))

    // Order reads its decision model (after = the sync's position)…
    let query: Reventless.DcbTag.query = [{tags: [tag("orderId", "O1")]}, {tags: [productTag]}]
    let after = (await readAfter(table, query))->Option.getOr("")
    expect(after == "")->toBe(false)

    // …a concurrent re-sync advances fence#productId:P5 past `after`. We set the
    // fence directly (rather than racing a second appendUnconditional) so the
    // advance is deterministically > after — same-millisecond writers can
    // otherwise tie on UUID order (analysis Issue 7). Appending "z" stays
    // lexically greater than any real position.
    let _ = await H.setFence(table, productTag, ~lastPosition=after ++ "z")

    // …so the now-stale order append must conflict on the productId fence.
    let r = await Runtime.appendConditional(
      table,
      [event("OrderPlaced", [tag("orderId", "O1"), tag("customerId", "C1"), productTag])],
      {query, after: ?Some(after)},
      ~partitionTag=simple("orderId"),
    )
    expect(isConflict(r))->toBe(true)
  })

  testAsync("placing an order does not poison the customer slice (secondary customerId not fenced)", async () => {
    let table = await H.freshTable()
    let customerTag = tag("customerId", "C1")

    // Customer exists (partitioned by customerId) → fence#customerId:C1 seeded.
    let _ = await seed(table, event("CustomerRegistered", [customerTag]), ~partitionTag=simple("customerId"))

    // Order for C1 carries customerId as a SECONDARY tag (partitioned by orderId).
    let orderQuery: Reventless.DcbTag.query = [{tags: [tag("orderId", "O1")]}]
    let orderAfter = await readAfter(table, orderQuery)
    let _ = await Runtime.appendConditional(
      table,
      [event("OrderPlaced", [tag("orderId", "O1"), customerTag, productTag])],
      {query: orderQuery, after: ?orderAfter},
      ~partitionTag=simple("orderId"),
    )

    // The customer slice reads its own partition (sees only CustomerRegistered)
    // and changes the email. Pre-fix the order would have bumped
    // fence#customerId:C1, falsely conflicting this append.
    let customerQuery: Reventless.DcbTag.query = [{tags: [customerTag]}]
    let customerAfter = await readAfter(table, customerQuery)
    let r = await Runtime.appendConditional(
      table,
      [event("EmailChanged", [customerTag])],
      {query: customerQuery, after: ?customerAfter},
      ~partitionTag=simple("customerId"),
    )
    expect(isOk(r))->toBe(true)
  })
})

describe("DCB DynamoDb integration — optimistic concurrency primitives", () => {
  testAsync("fresh first-writer (after=None) succeeds and seeds the fence", async () => {
    let table = await H.freshTable()
    let query: Reventless.DcbTag.query = [{tags: [tag("counterId", "K0")]}]
    let r = await Runtime.appendConditional(
      table,
      [event("CounterStarted", [tag("counterId", "K0")])],
      {query, after: ?None},
      ~partitionTag=simple("counterId"),
    )
    expect(isOk(r))->toBe(true)

    // The seeded event is now readable.
    let after = await readAfter(table, query)
    expect(after->Option.isSome)->toBe(true)
  })

  testAsync("two concurrent commits at the same after never both win (no duplicate)", async () => {
    let table = await H.freshTable()
    let counterTag = tag("counterId", "K1")
    let _ = await seed(table, event("CounterStarted", [counterTag]), ~partitionTag=simple("counterId"))

    let query: Reventless.DcbTag.query = [{tags: [counterTag]}]
    let after = await readAfter(table, query)

    let increment = () =>
      Runtime.appendConditional(
        table,
        [event("CounterIncremented", [counterTag])],
        {query, after: ?after},
        ~partitionTag=simple("counterId"),
      )

    let results = await Promise.all([increment(), increment()])
    let oks = results->Array.filter(isOk)->Array.length
    let conflicts = results->Array.filter(isConflict)->Array.length
    // Safety invariant at the raw-append layer: at most one writer commits, and
    // every non-winner surfaces a Conflict. (DynamoDB may cancel BOTH with a
    // mutual TransactionConflict — there is no retry here; the slice callback's
    // 3-retry loop is what turns this into a guaranteed single winner in prod.)
    expect(oks <= 1)->toBe(true)
    expect(oks + conflicts)->toBe(2)
    expect(conflicts >= 1)->toBe(true)
  })

  testAsync("a chain of compatible commits all succeed", async () => {
    let table = await H.freshTable()
    let counterTag = tag("counterId", "K2")
    let _ = await seed(table, event("CounterStarted", [counterTag]), ~partitionTag=simple("counterId"))
    let query: Reventless.DcbTag.query = [{tags: [counterTag]}]

    let step = async () => {
      let after = await readAfter(table, query)
      await Runtime.appendConditional(
        table,
        [event("CounterIncremented", [counterTag])],
        {query, after: ?after},
        ~partitionTag=simple("counterId"),
      )
    }

    let r1 = await step()
    let r2 = await step()
    let r3 = await step()
    expect([r1, r2, r3]->Array.every(isOk))->toBe(true)
  })

  testAsync("a failed fence condition aborts the whole transaction (multi-tag atomicity)", async () => {
    let table = await H.freshTable()
    // Composite slice: one multi-tag clause → both tags get check+bump.
    let tags = [tag("productId", "p1"), tag("orderId", "o1")]
    let query: Reventless.DcbTag.query = [{tags: tags}]

    // Seed one event so the next append rides after=Some.
    let seedRes = await Runtime.appendConditional(
      table,
      [event("ProductDemandRecorded", tags)],
      {query, after: ?None},
      ~partitionTag=simple("productId"),
    )
    expect(isOk(seedRes))->toBe(true)

    let after = (await readAfter(table, query))->Option.getOr("")
    expect(after == "")->toBe(false)

    // A concurrent writer advances ONLY the productId fence past `after`.
    // Appending "z" keeps the position lexically greater than any real position.
    let _ = await H.setFence(table, tag("productId", "p1"), ~lastPosition=after ++ "z")

    let r = await Runtime.appendConditional(
      table,
      [event("ProductDemandRecorded", tags)],
      {query, after: ?Some(after)},
      ~partitionTag=simple("productId"),
    )
    expect(isConflict(r))->toBe(true)

    // Atomic rollback: the second event was NOT written — the composite read
    // still returns exactly the one seeded event.
    let readResult = await Runtime.read(table)(~query)
    expect(readResult.events->Array.length)->toBe(1)
  })
})
