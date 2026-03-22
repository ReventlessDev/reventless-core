// Shared runtime utilities for compiled Lambda entry points.
// Replaces the hand-written HandlerFactoryHelpers.mjs.

// === Imports for %raw functions ===
// IdString for patchSpecId; DynamoDB SDK for scanByTableName.
// %%raw produces top-level JS — ESM import declarations are hoisted by the engine.
%%raw(`import { $$String as IdString } from "@reventlessdev/reventless-spec/src/types/Id.res.mjs"`)
%%raw(`import { DynamoDBClient } from "@aws-sdk/client-dynamodb"`)
%%raw(`import { DynamoDBDocumentClient, ScanCommand } from "@aws-sdk/lib-dynamodb"`)

// Patch a spec module's Id field to use IdString if undefined.
// Workaround for `module Id = Id.String` not producing an ESM export.
let patchSpecId: 'a => 'a = %raw(`(specModule) => ({ ...specModule, Id: specModule.Id || IdString })`)

// Create a minimal DynamoDB table stub from a table name.
type tableRef = {name: string, hashKey: string}
let makeTableRef = (name: string): tableRef => {name, hashKey: "id"}

// Create a minimal SQS queue stub from a queue URL.
type queueRef = {id: string, name: string, arn: string}
let makeQueueRef = (url: string): queueRef => {id: url, name: url, arn: ""}

// DynamoDB scan with filter expression support.
// Inline implementation to avoid importing QueryEngine_DynamoDb which
// mixes deploy-time Pulumi code with runtime logic.
let scanByTableName: (string, JSON.t, int) => promise<array<JSON.t>> = %raw(`async function(tableName, filterConfigs, limit) {
  if (!scanByTableName._client) {
    scanByTableName._client = DynamoDBDocumentClient.from(new DynamoDBClient({}));
  }
  var client = scanByTableName._client;
  var filterParts = [];
  var attrNames = {};
  var attrValues = {};

  (filterConfigs || []).forEach(function(entry, idx) {
    var fieldName = entry[0];
    var comparator = entry[1];
    var value = entry[2];
    var valueName = fieldName + idx;
    attrNames["#" + fieldName] = fieldName;

    var attrValue;
    if (typeof value === "object" && value !== null && "TAG" in value) {
      attrValue = value._0;
    } else {
      attrValue = value;
    }
    attrValues[":" + valueName] = attrValue;

    var comp = typeof comparator === "object" ? comparator.TAG || comparator : comparator;
    switch (comp) {
      case "Equal": filterParts.push("#" + fieldName + " = :" + valueName); break;
      case "Unequal": filterParts.push("#" + fieldName + " <> :" + valueName); break;
      case "Contains": filterParts.push("contains( #" + fieldName + ", :" + valueName + " )"); break;
      case "NotContains": filterParts.push("NOT contains( #" + fieldName + ", :" + valueName + " )"); break;
      case "BeginsWith": filterParts.push("begins_with( #" + fieldName + ", :" + valueName + " )"); break;
      case "Exists": filterParts.push("attribute_exists( #" + fieldName + " )"); break;
      case "NotExists": filterParts.push("attribute_not_exists( #" + fieldName + " )"); break;
      case "LessOrEqual": filterParts.push("#" + fieldName + " <= :" + valueName); break;
      case "Less": filterParts.push("#" + fieldName + " < :" + valueName); break;
      case "GreaterOrEqual": filterParts.push("#" + fieldName + " >= :" + valueName); break;
      case "Greater": filterParts.push("#" + fieldName + " > :" + valueName); break;
      default: filterParts.push("#" + fieldName + " = :" + valueName);
    }
  });

  var params = { TableName: tableName, Limit: limit };
  if (filterParts.length > 0) {
    params.FilterExpression = filterParts.join(" AND ");
    params.ExpressionAttributeNames = attrNames;
    params.ExpressionAttributeValues = attrValues;
  }

  var items = [];
  var lastKey;
  do {
    if (lastKey) params.ExclusiveStartKey = lastKey;
    var result = await client.send(new ScanCommand(params));
    if (result.Items) items.push.apply(items, result.Items);
    lastKey = result.LastEvaluatedKey;
  } while (lastKey && items.length < limit);

  return items;
}`)
