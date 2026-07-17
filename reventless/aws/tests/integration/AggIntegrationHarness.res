// Test-only harness for the Aggregate EventLog integration suite.
//
// Boots against a DynamoDB Local instance (see
// `scripts/run-integration-tests.sh` + `docker-compose.dynamodb-local.yml`); the
// production adapter's singleton DynamoDB client resolves its endpoint from
// `AWS_ENDPOINT_URL_DYNAMODB` (set by `jest.integration.setup.cjs`).
//
// The aggregate EventLog table is a plain `id` (HASH) + `position` (RANGE) table
// — no tag GSIs (that is the DCB store). Mirrors the deploy-time schema in
// `EventLogStorage_DynamoDb.res` (`~attributes=[id, position], ~rangeKey=position`).

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

let createEventLogTable = async (tableName): Util_DynamoDb_Runtime.resolvedTable => {
  let input =
    Dict.fromArray([
      ("TableName", s(tableName)),
      ("AttributeDefinitions", [attrDef("id"), attrDef("position")]->JSON.Encode.array),
      ("KeySchema", [keyEl("id", "HASH"), keyEl("position", "RANGE")]->JSON.Encode.array),
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
