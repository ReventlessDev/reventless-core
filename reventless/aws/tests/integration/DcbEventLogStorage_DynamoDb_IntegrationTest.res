// Fence model: PER-TYPE `pos#<eventType>` attributes with the create guard folded
// into the fence Update (dcb-fence-event-type-granularity). Conflict-expecting
// scenarios name the consumed event type on each query clause (a tag-only clause
// produces no fence check) and advance the fence via `H.setFence(~eventTypes,
// ~position=…)`, which writes the matching `pos#<eventType>` attribute — the same
// attribute a real conditional append checks. Not run by the default unit suite
// (CI `pnpm test`), so it does not gate the build.
//
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
  | Error(ReventlessInfra.DcbEventLog.Conflict) => true
  | Error(StorageFailure(_)) => false
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

    // Order reads its decision model (after = the sync's position). Each clause
    // names the event type it reads — the per-type fence model checks the
    // consumed type's `pos#<type>`, so a tag-only clause would produce no fence
    // check at all.
    let query: Reventless.DcbTag.query = [
      {tags: [tag("orderId", "O1")], eventTypes: ["OrderPlaced"]},
      {tags: [productTag], eventTypes: ["CatalogProductSynced"]},
    ]
    let after = (await readAfter(table, query))->Option.getOr("")
    expect(after == "")->toBe(false)

    // …a concurrent re-sync advances fence#productId:P5's pos#CatalogProductSynced
    // past `after`. We set the fence directly (rather than racing a second
    // appendUnconditional) so the advance is deterministically > after —
    // same-millisecond writers can otherwise tie on UUID order (analysis Issue 7).
    // Appending "z" stays lexically greater than any real position.
    let _ = await H.setFence(table, productTag, ~eventTypes=["CatalogProductSynced"], ~position=after ++ "z")

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

  testAsync("two concurrent first-writers to the same entity — exactly one creates it (Issue 2)", async () => {
    let table = await H.freshTable()
    // Both writers read an empty decision model (after=None) and try to create
    // the same order. The per-(eventType, partition) create guard must let only
    // one through.
    let create = () =>
      Runtime.appendConditional(
        table,
        [event("OrderCreated", [tag("orderId", "O1")])],
        {query: [{tags: [tag("orderId", "O1")]}], after: ?None},
        ~partitionTag=simple("orderId"),
      )

    let results = await Promise.all([create(), create()])
    let oks = results->Array.filter(isOk)->Array.length
    // Safety: the two first-writers must NOT both create the entity. At most one
    // commits; every non-winner surfaces a Conflict. (DynamoDB may cancel both
    // with a mutual TransactionConflict — the slice callback's retry loop then
    // makes exactly one win. Pre-fix this asserted-2: both committed = duplicate.)
    expect(oks <= 1)->toBe(true)
    expect(oks + results->Array.filter(isConflict)->Array.length)->toBe(2)

    // No duplicate landed — persisted OrderCreated count matches the winners.
    let readResult = await Runtime.read(table)(~query=[{tags: [tag("orderId", "O1")]}])
    expect(readResult.events->Array.length)->toBe(oks)
  })

  testAsync("the create guard does not false-conflict a subset-event-type writer (Issue 4)", async () => {
    let table = await H.freshTable()
    // A productId partition already holds a ProductAdded (its own create guard +
    // fence). A different slice reads only NameChanged on that partition, sees
    // nothing (after=None), and appends the first NameChanged. Its guard is
    // create#NameChanged#productId:P — distinct from ProductAdded's — so it must
    // NOT conflict with the pre-existing partition state.
    let productTag = tag("productId", "P")
    let r1 = await Runtime.appendConditional(
      table,
      [event("ProductAdded", [productTag])],
      {query: [{tags: [productTag]}], after: ?None},
      ~partitionTag=simple("productId"),
    )
    expect(isOk(r1))->toBe(true)

    let r2 = await Runtime.appendConditional(
      table,
      [event("NameChanged", [productTag])],
      {query: [{tags: [productTag]}], after: ?None},
      ~partitionTag=simple("productId"),
    )
    expect(isOk(r2))->toBe(true)
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
    // Composite slice: one multi-tag clause → both tags get check+bump. The
    // clause names the consumed type so the per-type fence check has a `pos#<type>`
    // to assert against.
    let tags = [tag("productId", "p1"), tag("orderId", "o1")]
    let query: Reventless.DcbTag.query = [{tags: tags, eventTypes: ["ProductDemandRecorded"]}]

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

    // A concurrent writer advances ONLY the productId fence's pos#ProductDemandRecorded
    // past `after`. Appending "z" keeps the position lexically greater than any real one.
    let _ = await H.setFence(
      table,
      tag("productId", "p1"),
      ~eventTypes=["ProductDemandRecorded"],
      ~position=after ++ "z",
    )

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

// A `@compositePartitionTag` slice (platform-inspector's SyncResource shape) fences
// on the WHOLE composite key, not on each member. Distinct entities sharing a
// low-cardinality prefix (environment/platformName/pluginName) must therefore NOT
// serialize on that prefix — the deploy-fan-out hot-fence regression. Plan:
// docs/plans/Backlog/dcb-hot-tag-fence-contention.md § "Root-cause correction".
describe("DCB DynamoDb integration — composite partition hot-fence fix", () => {
  let composite = (keys, seps): Reventless.DcbTag.derivedPartitionTag => Composite({keys, seps})
  let specKeys = ["environment", "platformName", "pluginName", "resourceName"]
  let specSeps = ["/", "/", "/"]
  let pt = composite(specKeys, specSeps)
  let members = resourceName => [
    tag("environment", "prod"),
    tag("platformName", "plat"),
    tag("pluginName", "plug"),
    tag("resourceName", resourceName),
  ]

  testAsync("distinct composite entities sharing a prefix do NOT false-conflict", async () => {
    let table = await H.freshTable()
    let tagsA = members("resA")
    let tagsB = members("resB")
    // Both are first-writers (after=None). They share environment/platformName/
    // pluginName but are DIFFERENT composite entities → different composite fences.
    let rA = await Runtime.appendConditional(
      table,
      [event("ResourceAdded", tagsA)],
      {query: [{tags: tagsA}], after: ?None},
      ~partitionTag=pt,
    )
    let rB = await Runtime.appendConditional(
      table,
      [event("ResourceAdded", tagsB)],
      {query: [{tags: tagsB}], after: ?None},
      ~partitionTag=pt,
    )
    // Pre-fix: rB conflicts on the shared `fence#environment:prod` create guard.
    expect(isOk(rA))->toBe(true)
    expect(isOk(rB))->toBe(true)
  })

  testAsync("two first-writers of the SAME composite key still serialize (OCC preserved)", async () => {
    let table = await H.freshTable()
    let tags = members("resA")
    let query: Reventless.DcbTag.query = [{tags: tags}]
    let r1 = await Runtime.appendConditional(
      table,
      [event("ResourceAdded", tags)],
      {query, after: ?None},
      ~partitionTag=pt,
    )
    let r2 = await Runtime.appendConditional(
      table,
      [event("ResourceAdded", tags)],
      {query, after: ?None},
      ~partitionTag=pt,
    )
    expect(isOk(r1))->toBe(true)
    // The folded create guard (attribute_not_exists on the composite fence) rejects
    // the second first-write of the same entity.
    expect(isConflict(r2))->toBe(true)
  })
})

// The fence is PER event type (`pos#<eventType>` attributes), not a single scalar
// `lastPosition` per partition. So two slices consuming DIFFERENT types on the same
// entity (e.g. price vs name changes on one productId) never contend, and an entity
// never wedges into a permanent Conflict after one attribute changes. This is the
// live proof of the per-type granularity fix (dcb-fence-event-type-granularity,
// `a20646f31`); the unit suite only asserts the built transaction's shape.
describe("DCB DynamoDb integration — per-type fence granularity", () => {
  let productTag = tag("productId", "P")

  // Change one attribute of P: read only its own event type on the partition, then
  // append that type. Each type carries its own `pos#<type>` fence, so distinct
  // attributes advance independently.
  let change = async (table, ~eventType) => {
    let query: Reventless.DcbTag.query = [{tags: [productTag], eventTypes: [eventType]}]
    let after = await readAfter(table, query)
    await Runtime.appendConditional(
      table,
      [event(eventType, [productTag])],
      {query, after: ?after},
      ~partitionTag=simple("productId"),
    )
  }

  testAsync("interleaved distinct-type changes on one product all succeed (never wedges)", async () => {
    let table = await H.freshTable()
    let _ = await seed(table, event("ProductAdded", [productTag]), ~partitionTag=simple("productId"))

    // Two rounds of interleaved price/name/description changes. Pre-fix, the first
    // PriceChanged bumped the single partition fence, so the following NameChanged
    // read a stale head and conflicted PERMANENTLY — the entity wedged after one edit.
    let results = [
      await change(table, ~eventType="PriceChanged"),
      await change(table, ~eventType="NameChanged"),
      await change(table, ~eventType="DescriptionChanged"),
      await change(table, ~eventType="PriceChanged"),
      await change(table, ~eventType="NameChanged"),
    ]
    expect(results->Array.every(isOk))->toBe(true)
  })

  testAsync("two concurrent SAME-type changes still serialize (per-type OCC preserved)", async () => {
    let table = await H.freshTable()
    let _ = await seed(table, event("ProductAdded", [productTag]), ~partitionTag=simple("productId"))
    // Seed one NameChanged so both racers read the same after=Some head.
    let _ = await change(table, ~eventType="NameChanged")

    let query: Reventless.DcbTag.query = [{tags: [productTag], eventTypes: ["NameChanged"]}]
    let after = await readAfter(table, query)
    let rename = () =>
      Runtime.appendConditional(
        table,
        [event("NameChanged", [productTag])],
        {query, after: ?after},
        ~partitionTag=simple("productId"),
      )

    // Per-type granularity must NOT weaken same-type OCC: two concurrent NameChanged
    // at the same `pos#NameChanged` head → at most one commits, every non-winner
    // conflicts. (DynamoDB may cancel both with a mutual TransactionConflict; the
    // slice callback's retry loop makes exactly one win in prod.)
    let results = await Promise.all([rename(), rename()])
    let oks = results->Array.filter(isOk)->Array.length
    let conflicts = results->Array.filter(isConflict)->Array.length
    expect(oks <= 1)->toBe(true)
    expect(oks + conflicts)->toBe(2)
    expect(conflicts >= 1)->toBe(true)
  })
})

// An empty tag value is a legitimate model state (an absent member of a composite
// partition key), and the in-memory and SQLite backends have always accepted one.
// DynamoDB used to reject the whole append: `tag_<key>` is a GSI hash key and a key
// attribute cannot hold an empty string. The adapter now skips that one attribute,
// leaving the index sparse — everything else about the event is unchanged.
// See docs/plans/dcb-empty-tag-values-break-append.md.
describe("DCB DynamoDb integration — an empty tag value does not break the append", () => {
  let tags = [tag("orderId", "O-empty"), tag("customerId", "")]

  testAsync("appends, and reads back through its partition with the tag intact", async () => {
    let table = await H.freshTable()
    let result = await Runtime.appendConditional(
      table,
      [event("OrderPlaced", tags)],
      {query: [{tags: tags}], after: ?None},
      ~partitionTag=simple("orderId"),
    )
    expect(isOk(result))->toBe(true)

    let byPartition = await Runtime.read(table)(~query=[{tags: [tag("orderId", "O-empty")]}])
    expect(byPartition.events->Array.length)->toBe(1)
    let stored = byPartition.events->Array.getUnsafe(0)
    expect(stored.eventType)->toBe("OrderPlaced")
    // The event records the empty value verbatim — only the index skips it.
    expect(stored.tags->Array.map(t => (t.key, t.value)))->toEqual([
      ("orderId", "O-empty"),
      ("customerId", ""),
    ])
  })

  testAsync("is found by a composite (multi-tag) read", async () => {
    let table = await H.freshTable()
    let _ = await Runtime.appendUnconditional(
      table,
      [event("OrderPlaced", tags)],
      ~partitionTag=simple("orderId"),
    )
    let composite = await Runtime.read(table)(~query=[{tags: tags}])
    expect(composite.events->Array.length)->toBe(1)
  })

  testAsync("is absent from that tag's single-tag index rather than erroring", async () => {
    let table = await H.freshTable()
    let _ = await Runtime.appendUnconditional(
      table,
      [event("OrderPlaced", tags)],
      ~partitionTag=simple("orderId"),
    )
    // A cross-partition read goes through the `tag_customerId` GSI, which carries
    // no empty-valued key. DynamoDB would reject the key condition outright, so the
    // adapter short-circuits: empty result, no exception.
    let crossPartition = await Runtime.read(table, ~crossPartitionTagKeys=["customerId"])(
      ~query=[{tags: [tag("customerId", "")]}],
    )
    expect(crossPartition.events->Array.length)->toBe(0)
  })
})
