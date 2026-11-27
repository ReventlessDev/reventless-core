// An order quotes the fee of every delivery option, end to end on DynamoDB Local: two slice
// callbacks over one event log, wired with the scope the deployed command handler derives. Each fee
// is stored under its delivery option, and the order reads them all by their kind tag's index; a fee
// set between the order's read and its append moves the kind's fence, so the append is refused.

open JestGlobals

module H = DcbIntegrationHarness
module D = DeliverySlices

let slices: array<Reventless.DcbTag.sliceSchemas> = [
  {
    name: D.SetDeliveryFee.name,
    commandSchema: D.SetDeliveryFee.commandSchema->S.castToUnknown,
    consumedEventSchema: D.SetDeliveryFee.consumedEventSchema->S.castToUnknown,
    eventSchema: D.SetDeliveryFee.eventSchema->S.castToUnknown,
    moduleUrl: D.SetDeliveryFee.moduleUrl,
  },
  {
    name: D.PlaceOrder.name,
    commandSchema: D.PlaceOrder.commandSchema->S.castToUnknown,
    consumedEventSchema: D.PlaceOrder.consumedEventSchema->S.castToUnknown,
    eventSchema: D.PlaceOrder.eventSchema->S.castToUnknown,
    moduleUrl: D.PlaceOrder.moduleUrl,
  },
]

// The scope as the deployed command handler derives it.
let effective = Reventless.DcbTag.deriveEffectiveScope(slices)
let boundary = Reventless.DcbTag.deriveBoundaryPartition(slices)
let partitionOf = name => boundary->Reventless.DcbTag.slicePartitionTag(name)
let scope: DcbCommandTopicEntryPoint_Ops.derivedScope = {
  crossPartitionTagKeys: effective.crossPartitionTagKeys,
  crossPartitionPairs: effective.crossPartitionPairs,
  tagKeysByEventType: effective.tagKeysByEventType,
  partitionTag: boundary.partitionTag,
  partitionTagBySlice: slices
  ->Array.filterMap(s => partitionOf(s.name)->Option.map(p => (s.name, p)))
  ->Dict.fromArray,
}

let eventLogOf = (
  table: Util_DynamoDb_Runtime.resolvedTable,
): ReventlessInfra.DcbEventLog.operations => {
  module Ops = ReventlessCore.DcbEventLog_Operations.Make({
    let name = "Shop"
    let serviceName = "ShopDcbEventLog"
    let storage = DcbCommandTopicEntryPoint_Ops.makeDynamoStorageOps(~tableName=table.name, scope)
    let publishJson = async (_, _, _) => ()
  })
  {
    read: Ops.read,
    append: Ops.append,
    readStream: Ops.readStream,
    appendStream: Ops.appendStream,
    readFences: ?Ops.readFences,
  }
}

module SetDeliveryFee = ReventlessCore.StateChangeSlice_Callback.Make(
  D.SetDeliveryFee,
  D.SetDeliveryFeeDecision,
)
module PlaceOrder = ReventlessCore.StateChangeSlice_Callback.Make(
  D.PlaceOrder,
  D.PlaceOrderDecision,
)

let counter = ref(0)
let item = (sliceName, command) => {
  counter := counter.contents + 1
  let reference = `${sliceName}-${counter.contents->Int.toString}`
  {
    ReventlessInfra.CommandTopic.command: {
      ReventlessCore.Message.id: Reventless.Id.String.makeFromString(`cmd-${reference}`),
      meta: ReventlessCore.Message.generateMeta(~service="delivery-it"),
      command,
    },
    reference,
  }
}
let accepted = (result: array<result<string, string>>) =>
  switch result {
  | [Ok(_)] => true
  | _ => false
  }

let setFee = (log, deliveryOptionId, fee) =>
  SetDeliveryFee.handleCommands(
    ~tagKeysByEventType=scope.tagKeysByEventType,
    ~crossPartitionTagKeys=scope.crossPartitionTagKeys,
    ~crossPartitionPairs=scope.crossPartitionPairs,
    ~partitionTag=?partitionOf(D.SetDeliveryFee.name),
    log,
    Stream.fromIterable([item("fee", D.SetDeliveryFee.SetDeliveryFee({deliveryOptionId, fee}))]),
  )
  ->Effect.runPromise
  ->Promise.thenResolve(accepted)
let placeOrder = (log, orderId) =>
  PlaceOrder.handleCommands(
    ~tagKeysByEventType=scope.tagKeysByEventType,
    ~crossPartitionTagKeys=scope.crossPartitionTagKeys,
    ~crossPartitionPairs=scope.crossPartitionPairs,
    ~partitionTag=?partitionOf(D.PlaceOrder.name),
    log,
    Stream.fromIterable([item("order", D.PlaceOrder.PlaceOrder({orderId: orderId}))]),
  )
  ->Effect.runPromise
  ->Promise.thenResolve(accepted)

let kind = Reventless.DcbTag.kindTag("DeliveryFeeSet")

let freshTable = async () => {
  counter := counter.contents + 1
  let table = await H.createDcbTableWithTagKeys(
    `DcbWholeIt_${counter.contents->Int.toString}`,
    ["deliveryOptionId", "orderId", Reventless.DcbTag.kindTagKey],
  )
  // On an empty table every fence is counted, so each written from now on is trusted.
  let _ = await DcbFenceBackfill.countAll(
    table,
    ~keys=[Reventless.DcbTag.kindTagKey],
    ~pairs=[],
    ~recount=false,
    ~settleMs=0,
    ~dryRun=false,
  )
  table
}

let _ = beforeEach(() => {
  SetDeliveryFee.resetCache()
  PlaceOrder.resetCache()
})

// The quote an order was placed with: (delivery option, fee), in order.
let quoteOf = async (table, orderId) =>
  (
    await DcbEventLogStorage_DynamoDb_Runtime.read(table)(
      ~query=[{tags: [{key: "orderId", value: orderId}], eventTypes: ["OrderPlaced"]}],
    )
  ).events
  ->Array.filter(e => e.eventType == "OrderPlaced")
  ->Array.flatMap(e =>
    e.data
    ->JSON.Decode.object
    ->Option.flatMap(o => o->Dict.get("quote"))
    ->Option.flatMap(JSON.Decode.array)
    ->Option.getOr([])
    ->Array.filterMap(line =>
      line
      ->JSON.Decode.object
      ->Option.flatMap(
        l =>
          switch (
            l->Dict.get("deliveryOption")->Option.flatMap(JSON.Decode.string),
            l->Dict.get("fee")->Option.flatMap(JSON.Decode.float),
          ) {
          | (Some(option), Some(fee)) => Some((option, fee))
          | _ => None
          },
      )
    )
  )
let kindFenceOf = async table =>
  (await DcbEventLogStorage_DynamoDb_Runtime.readFences(table)([kind]))->Array.map(f => (
    f.counted,
    f.counts->Dict.toArray,
  ))

// What PlaceOrder's command reads: its order, and every fee by its kind.
let orderQuery = (orderId): Reventless.DcbTag.query =>
  Reventless.DcbTag.buildQueryFromCommand(
    ~eventTypes=["OrderPlaced", "DeliveryFeeSet"],
    ~schema=D.PlaceOrder.commandSchema,
    ~value=D.PlaceOrder.PlaceOrder({orderId: orderId}),
    ~tagKeysByEventType=scope.tagKeysByEventType,
    ~crossPartitionTagKeys=scope.crossPartitionTagKeys,
    ~wholeEventTypes=Reventless.DcbTag.wholeEventTypesOfSchema(D.PlaceOrder.consumedEventSchema),
  )

describe("DCB DynamoDb integration — an order reads every delivery fee whole", () => {
  testSync("the boundary resolves, and reads the fees by their kind across partitions", () => {
    expect((
      effective.ambiguities,
      effective.wholeEventTypes,
      effective.crossPartitionTagKeys,
      effective.tagKeysByEventType->Dict.get("DeliveryFeeSet"),
      orderQuery("o1"),
    ))->toEqual((
      [],
      ["DeliveryFeeSet"],
      [Reventless.DcbTag.kindTagKey],
      Some(["deliveryOptionId", Reventless.DcbTag.kindTagKey]),
      [
        {Reventless.DcbTag.eventTypes: ["OrderPlaced"], tags: [{key: "orderId", value: "o1"}]},
        {eventTypes: ["DeliveryFeeSet"], tags: [kind]},
      ],
    ))
  })

  testAsync("quotes the fee of every delivery option, each stored under its own", async () => {
    let table = await freshTable()
    let log = eventLogOf(table)
    let _ = await setFee(log, "standard", 4.9)
    let _ = await setFee(log, "express", 9.9)
    let _ = await setFee(log, "standard", 5.9)
    let placed = await placeOrder(log, "o1")
    expect((placed, await quoteOf(table, "o1"), await kindFenceOf(table)))->toEqual((
      true,
      [("express", 9.9), ("standard", 5.9)],
      [(true, [("DeliveryFeeSet", 3)])],
    ))
  })

  testAsync("refuses an append that did not see a fee set since its read", async () => {
    let table = await freshTable()
    let log = eventLogOf(table)
    let _ = await setFee(log, "standard", 4.9)
    let query = orderQuery("o1")
    let read = await log.read(~query)
    let fences = await DcbEventLogStorage_DynamoDb_Runtime.readFences(table)([kind])
    let clauses = Reventless.DcbFenceCount.clauses(
      query,
      ~crossPartitionTagKeys=scope.crossPartitionTagKeys,
    )
    let seen = Dict.make()
    read.events->Array.forEach(
      e => seen->Reventless.DcbFenceCount.countRead(clauses, ~eventType=e.eventType, ~tags=e.tags),
    )
    let condition: Reventless.DcbTag.appendCondition = {
      query,
      after: ?read.headPosition,
      fenceCounts: Reventless.DcbFenceCount.readCounts(fences, clauses, seen),
    }
    let order: ReventlessInfra.DcbEventLog.rawEvent = {
      eventType: "OrderPlaced",
      data: Dict.fromArray([
        ("orderId", JSON.Encode.string("o1")),
        ("quote", []->JSON.Encode.array),
      ])->JSON.Encode.object,
      tags: [{key: "orderId", value: "o1"}],
      meta: ReventlessCore.Message.generateMeta(~service="delivery-it"),
    }
    // Another option's fee, stored under another partition, set after the read.
    let _ = await setFee(log, "express", 9.9)
    let stale = await log.append([order], ~condition)
    // Placed through the slice, the order reads again and quotes both.
    let placed = await placeOrder(log, "o1")
    expect((stale, placed, await quoteOf(table, "o1")))->toEqual((
      Error(ReventlessInfra.DcbEventLog.Conflict),
      true,
      [("express", 9.9), ("standard", 4.9)],
    ))
  })

  testAsync("tag-kinds tags the fees stored before the kind was read whole", async () => {
    let table = await freshTable()
    let log = eventLogOf(table)
    // Written by a deploy that read no kind whole: no kind tag.
    let feeBefore = (option, fee): ReventlessInfra.DcbEventLog.rawEvent => {
      eventType: "DeliveryFeeSet",
      data: Dict.fromArray([
        ("deliveryOptionId", JSON.Encode.string(option)),
        ("fee", JSON.Encode.float(fee)),
      ])->JSON.Encode.object,
      tags: [{key: "deliveryOptionId", value: option}],
      meta: ReventlessCore.Message.generateMeta(~service="delivery-it"),
    }
    let _ = await log.append([feeBefore("standard", 4.9), feeBefore("express", 9.9)])
    let tagged = await DcbKindBackfill.tagKinds(
      table,
      ~eventTypes=["DeliveryFeeSet"],
      ~dryRun=false,
    )
    let again = await DcbKindBackfill.tagKinds(table, ~eventTypes=["DeliveryFeeSet"], ~dryRun=false)
    let _ = await DcbFenceBackfill.countAll(
      table,
      ~keys=[Reventless.DcbTag.kindTagKey],
      ~pairs=[],
      ~recount=true,
      ~settleMs=0,
      ~dryRun=false,
    )
    let placed = await placeOrder(log, "o1")
    expect((tagged, again, placed, await quoteOf(table, "o1"), await kindFenceOf(table)))->toEqual((
      [("DeliveryFeeSet", 2)],
      [("DeliveryFeeSet", 0)],
      true,
      [("express", 9.9), ("standard", 4.9)],
      [(true, [("DeliveryFeeSet", 2)])],
    ))
  })
})
