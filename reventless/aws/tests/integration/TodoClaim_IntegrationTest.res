// Two runtimes share an outbound translation's TODO rows: each claims a row before
// it translates it, and writes back only what it changed. Asserts DynamoDB's reading
// of the claim's conditions, which a unit test cannot (NOT run by the default unit
// suite; see `scripts/run-integration-tests.sh`).

open JestGlobals

module Ops = AutomationSliceEntryPoint_Ops
module Callback = ReventlessCore.OutboundTranslationSlice_Callback

type command

@new @module("@aws-sdk/client-dynamodb")
external describeTableCommand: JSON.t => command = "DescribeTableCommand"

@send
external sendRaw: (AwsSdk.DynamoDb.DynamoDb.client, command) => promise<JSON.t> = "send"

let s = JSON.Encode.string

let tableInput = name =>
  Dict.fromArray([
    ("TableName", s(name)),
    ("AttributeDefinitions", [DcbIntegrationHarness.attrDef("id")]->JSON.Encode.array),
    ("KeySchema", [DcbIntegrationHarness.keyEl("id", "HASH")]->JSON.Encode.array),
    ("BillingMode", s("PAY_PER_REQUEST")),
  ])->JSON.Encode.object

@get external tableOf: JSON.t => {"Table": {"TableStatus": string}} = "%identity"

/** A table of TODO rows, waited for until it can be written: DynamoDB Local makes
    one at once, AWS in a few seconds. */
let makeTable = async name => {
  let _ = await DcbIntegrationHarness.send(
    DcbIntegrationHarness.createTableCommand(tableInput(name)),
  )
  let active = ref(false)
  while !active.contents {
    let out = await sendRaw(
      AwsSdk.DynamoDb.DynamoDb.client(),
      describeTableCommand(Dict.fromArray([("TableName", s(name))])->JSON.Encode.object),
    )
    active := (out->tableOf)["Table"]["TableStatus"] == "ACTIVE"
    if !active.contents {
      await Promise.make((resolve, _) => setTimeout(() => resolve(), 1000)->ignore)
    }
  }
  name
}

let row = (~status: Callback.todoStatus, ~retryCount=0, ~claimedUntil=?): Callback.todoRow => {
  item: Dict.fromArray([("orderId", s("ord-1"))])->JSON.Encode.object,
  status,
  createdAt: "2026-11-17T00:00:00.000Z",
  retryCount,
  ?claimedUntil,
}

let claimedNow = (read: Callback.todoRow): Callback.todoRow => {
  ...read,
  status: Processing,
  claimedUntil: Date.fromTime(Date.now() +. Callback.claimMs)->Date.toISOString,
}

/** One runtime: its rows in memory, what it last wrote or read, and its three
    operations on the shared table. */
let runtime = tableName => {
  let todoItems: dict<Callback.todoRow> = Dict.make()
  let synced = Dict.make()
  (
    todoItems,
    Ops.makeLoadTodoItems(
      ~queryDbTableName=tableName,
      ~todoItems,
      ~rowSchema=Callback.todoRowSchema,
      ~comp="TodoClaimIt",
      ~synced,
    ),
    Ops.makeSyncTodoItems(
      ~queryDbTableName=tableName,
      ~todoItems,
      ~rowSchema=Callback.todoRowSchema,
      ~synced,
    ),
    Ops.makeClaimTodoItem(~queryDbTableName=tableName, ~synced),
  )
}

let stored = async (tableName, id) => {
  let out = await AwsSdk.DynamoDb.DocumentClient.GetCommand.send(
    AwsSdk.DynamoDb.DocumentClient.GetCommand.make({
      tableName,
      key: Dict.fromArray([("id", s(id))]),
      consistentRead: true,
    }),
  )
  out.item->Option.map(item => item->Reventless.Util_Sury.fromJson(Callback.todoRowSchema))
}

let tableName = `TodoClaimIt_${Date.now()->Float.toString}`

describe("two runtimes on one table of TODO rows", () => {
  beforeAllAsync(async () => {
    let _ = await makeTable(tableName)
  })

  afterAllAsync(async () => {
    let _ = await DcbIntegrationHarness.deleteTable({
      id: tableName,
      name: tableName,
      arn: "",
      hashKey: "id",
    })
  })

  testPromise("only the first to claim a row it both read translates it", async () => {
    let (itemsA, _loadA, syncA, claimA) = runtime(tableName)
    let (itemsB, loadB, syncB, claimB) = runtime(tableName)
    itemsA->Dict.set("both", row(~status=Pending))
    await syncA()
    await loadB()
    let a = await claimA("both", claimedNow(row(~status=Pending)))
    let b = await claimB("both", claimedNow(row(~status=Pending)))

    // B drops the row it could not claim, as phase 2 does, so its sync leaves
    // A's claim alone.
    if !b {
      itemsB->Dict.delete("both")
    }
    await syncB()
    let after = await stored(tableName, "both")
    expect((a, b, after->Option.map(r => r.status)))->toEqual((
      true,
      false,
      Some(Callback.Processing),
    ))
  })

  testPromise(
    "a row finished by one runtime is not claimed from another's stale copy",
    async () => {
      let (itemsA, _, syncA, claimA) = runtime(tableName)
      let (_, loadB, _, claimB) = runtime(tableName)
      itemsA->Dict.set("done", row(~status=Pending))
      await syncA()
      await loadB()
      let _ = await claimA("done", claimedNow(row(~status=Pending)))
      itemsA->Dict.set("done", {...row(~status=Pending), status: Completed})
      await syncA()
      let b = await claimB("done", claimedNow(row(~status=Pending)))
      let after = await stored(tableName, "done")
      expect((b, after->Option.map(r => r.status)))->toEqual((false, Some(Callback.Completed)))
    },
  )

  testPromise("a failed row is claimed only at the retry count it was read at", async () => {
    let (itemsA, _, syncA, _) = runtime(tableName)
    let (_, loadB, _, claimB) = runtime(tableName)
    let (_, loadC, _, claimC) = runtime(tableName)
    itemsA->Dict.set("failed", row(~status=Failed, ~retryCount=1))
    await syncA()
    await loadB()
    await loadC()
    let b = await claimB("failed", claimedNow(row(~status=Failed, ~retryCount=1)))
    let c = await claimC("failed", claimedNow(row(~status=Failed, ~retryCount=1)))
    expect((b, c))->toEqual((true, false))
  })

  testPromise("a Processing row is reclaimed only once its claim ran out", async () => {
    let (itemsA, _, syncA, _) = runtime(tableName)
    itemsA->Dict.set("ranOut", row(~status=Processing, ~claimedUntil="2026-01-01T00:00:00.000Z"))
    itemsA->Dict.set(
      "held",
      row(
        ~status=Processing,
        ~claimedUntil=Date.fromTime(Date.now() +. 600_000.)->Date.toISOString,
      ),
    )
    await syncA()
    let (itemsB, loadB, _, claimB) = runtime(tableName)
    await loadB()
    let ranOut = await claimB("ranOut", claimedNow(row(~status=Processing)))
    let held = await claimB("held", claimedNow(row(~status=Processing)))
    expect((
      itemsB->Dict.get("ranOut")->Option.isSome,
      itemsB->Dict.get("held")->Option.isSome,
      ranOut,
      held,
    ))->toEqual((true, false, true, false))
  })

  testPromise("a row no runtime has written is claimed once", async () => {
    let (_, _, _, claimA) = runtime(tableName)
    let (_, _, _, claimB) = runtime(tableName)
    let a = await claimA("fresh", claimedNow(row(~status=Pending)))
    let b = await claimB("fresh", claimedNow(row(~status=Pending)))
    expect((a, b))->toEqual((true, false))
  })
})
