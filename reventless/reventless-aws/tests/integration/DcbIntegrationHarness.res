// Test-only harness for the DCB DynamoDB integration suite.
//
// Boots against a DynamoDB Local instance (see
// `scripts/run-integration-tests.sh` + `docker-compose.dynamodb-local.yml`).
// The production adapter's singleton DynamoDB client (`AwsSdk.DynamoDb.*`)
// resolves its endpoint from `AWS_ENDPOINT_URL_DYNAMODB`, set by
// `jest.integration.setup.cjs`, so no binding changes are needed — the runtime
// under test talks to the local engine exactly as it would to AWS.
//
// This module only adds the table-lifecycle commands (`CreateTable`,
// `DeleteTable`) that the shared SDK package does not bind, since they are only
// ever needed for tests.

type command

@new @module("@aws-sdk/client-dynamodb")
external createTableCommand: JSON.t => command = "CreateTableCommand"

@new @module("@aws-sdk/client-dynamodb")
external deleteTableCommand: JSON.t => command = "DeleteTableCommand"

@send
external sendRaw: (AwsSdk.DynamoDb.DynamoDb.client, command) => promise<JSON.t> = "send"

let send = cmd => sendRaw(AwsSdk.DynamoDb.DynamoDb.client(), cmd)

let s = JSON.Encode.string

let attrDef = name =>
  Dict.fromArray([("AttributeName", s(name)), ("AttributeType", s("S"))])->JSON.Encode.object

let keyEl = (name, keyType) =>
  Dict.fromArray([("AttributeName", s(name)), ("KeyType", s(keyType))])->JSON.Encode.object

let gsi = indexName =>
  Dict.fromArray([
    ("IndexName", s(indexName)),
    ("KeySchema", [keyEl(indexName, "HASH"), keyEl("position", "RANGE")]->JSON.Encode.array),
    ("Projection", Dict.fromArray([("ProjectionType", s("ALL"))])->JSON.Encode.object),
  ])->JSON.Encode.object

// Superset of tag GSIs used across the scenarios. GSIs are sparse, so an event
// missing a given tag attribute is simply absent from that index — matching the
// production `Dcb_Builder` schema (one `tag_<key>` GSI per tagged field +
// `tag_composite`).
let gsiNames = ["tag_productId", "tag_orderId", "tag_customerId", "tag_counterId", "tag_composite"]

let createDcbTable = async (tableName): Util_DynamoDb_Runtime.resolvedTable => {
  let attributeDefinitions = Array.concat(
    [attrDef("id"), attrDef("position")],
    gsiNames->Array.map(attrDef),
  )
  let input =
    Dict.fromArray([
      ("TableName", s(tableName)),
      ("AttributeDefinitions", attributeDefinitions->JSON.Encode.array),
      ("KeySchema", [keyEl("id", "HASH"), keyEl("position", "RANGE")]->JSON.Encode.array),
      ("GlobalSecondaryIndexes", gsiNames->Array.map(gsi)->JSON.Encode.array),
      ("BillingMode", s("PAY_PER_REQUEST")),
    ])->JSON.Encode.object
  let _ = await send(createTableCommand(input))
  {
    Util_DynamoDb_Runtime.id: tableName,
    name: tableName,
    arn: `arn:aws:dynamodb:local:000000000000:table/${tableName}`,
    hashKey: "id",
  }
}

let deleteTable = async (table: Util_DynamoDb_Runtime.resolvedTable) => {
  let input = Dict.fromArray([("TableName", s(table.name))])->JSON.Encode.object
  let _ = await send(deleteTableCommand(input))
}

// Unique table per test so persisted fence sentinels never leak across scenarios.
let counter = ref(0)
let freshTable = async () => {
  counter := counter.contents + 1
  await createDcbTable(`DcbItTest_${counter.contents->Int.toString}`)
}

// Directly overwrite a fence sentinel's `lastPosition` — used to simulate a
// concurrent writer having advanced a fence between a slice's read and append.
let setFence = async (
  table: Util_DynamoDb_Runtime.resolvedTable,
  tag: Reventless.DcbTag.tag,
  ~lastPosition: string,
) => {
  let item =
    Dict.fromArray([
      ("id", s(DcbEventLogStorage_DynamoDb_Runtime.fencePartitionKey(tag))),
      ("position", s("FENCE")),
      ("lastPosition", s(lastPosition)),
    ])->JSON.Encode.object
  await Util_DynamoDb_Runtime.put(table, item)
}
