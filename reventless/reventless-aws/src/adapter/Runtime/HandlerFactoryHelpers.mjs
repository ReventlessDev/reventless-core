/**
 * Shared utilities for bundled Lambda handler factories.
 *
 * Extracted from the individual BundledXxxHandlerFactory.mjs files to reduce
 * duplication. All functions are pure utilities with no module-level side effects.
 */

import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand } from "@aws-sdk/lib-dynamodb";
import { $$String as IdString } from "@reventlessdev/reventless-spec/src/types/Id.res.mjs";

/**
 * Patch a spec module's Id field to use IdString if it's undefined.
 *
 * Workaround for ReScript ESM issue where `module Id = Id.String` doesn't
 * produce a runtime value, causing "import is undefined" warnings in esbuild.
 *
 * @param {Object} specModule - The spec module to patch
 * @returns {Object} A new object with Id defaulting to IdString
 */
export function patchSpecId(specModule) {
  return { ...specModule, Id: specModule.Id || IdString };
}

/**
 * Create a minimal DynamoDB table stub from a table name.
 * Used to reconstruct QueryDb table references at runtime.
 *
 * @param {string} name - DynamoDB table name
 * @returns {{ name: string, hashKey: string }}
 */
export function makeTableRef(name) {
  return { name, hashKey: "id" };
}

/**
 * Create a minimal SQS queue stub from a queue URL.
 * Used to reconstruct CommandTopic channel references at runtime.
 *
 * @param {string} url - SQS queue URL
 * @returns {{ id: string, name: string, arn: string }}
 */
export function makeQueueRef(url) {
  return { id: url, name: url, arn: "" };
}

// Shared DynamoDB client for scanByTableName — lazily initialized.
let _ddbClient = null;
function getDdbClient() {
  if (!_ddbClient) {
    _ddbClient = DynamoDBDocumentClient.from(new DynamoDBClient({}));
  }
  return _ddbClient;
}

/**
 * DynamoDB scan with filter expression support.
 *
 * Inline implementation to avoid importing QueryEngine_DynamoDb which pulls
 * in @pulumi/pulumi via its `make` function.
 *
 * Supports all 11 comparison operators from the ReScript QueryEngine.Filter type.
 *
 * @param {string} tableName - DynamoDB table name
 * @param {Array} filterConfigs - Array of [fieldName, comparator, value] tuples
 * @param {number} limit - Maximum number of items to return
 * @returns {Promise<Array>} Scanned items
 */
export async function scanByTableName(tableName, filterConfigs, limit) {
  const filterParts = [];
  const attrNames = {};
  const attrValues = {};

  (filterConfigs || []).forEach(([fieldName, comparator, value], idx) => {
    const valueName = `${fieldName}${idx}`;
    attrNames[`#${fieldName}`] = fieldName;

    // Extract the actual value from the tagged union
    let attrValue;
    if (typeof value === "object" && value !== null && "TAG" in value) {
      // ReScript tagged variant: String("x") -> { TAG: "String", _0: "x" }
      attrValue = value._0;
    } else {
      attrValue = value;
    }
    attrValues[`:${valueName}`] = attrValue;

    // Comparator is a ReScript variant - match the TAG
    const comp =
      typeof comparator === "object" ? comparator.TAG || comparator : comparator;
    switch (comp) {
      case "Equal":
        filterParts.push(`#${fieldName} = :${valueName}`);
        break;
      case "Unequal":
        filterParts.push(`#${fieldName} <> :${valueName}`);
        break;
      case "Contains":
        filterParts.push(`contains( #${fieldName}, :${valueName} )`);
        break;
      case "NotContains":
        filterParts.push(`NOT contains( #${fieldName}, :${valueName} )`);
        break;
      case "BeginsWith":
        filterParts.push(`begins_with( #${fieldName}, :${valueName} )`);
        break;
      case "Exists":
        filterParts.push(`attribute_exists( #${fieldName} )`);
        break;
      case "NotExists":
        filterParts.push(`attribute_not_exists( #${fieldName} )`);
        break;
      case "LessOrEqual":
        filterParts.push(`#${fieldName} <= :${valueName}`);
        break;
      case "Less":
        filterParts.push(`#${fieldName} < :${valueName}`);
        break;
      case "GreaterOrEqual":
        filterParts.push(`#${fieldName} >= :${valueName}`);
        break;
      case "Greater":
        filterParts.push(`#${fieldName} > :${valueName}`);
        break;
      default:
        filterParts.push(`#${fieldName} = :${valueName}`);
    }
  });

  const params = {
    TableName: tableName,
    Limit: limit,
  };
  if (filterParts.length > 0) {
    params.FilterExpression = filterParts.join(" AND ");
    params.ExpressionAttributeNames = attrNames;
    params.ExpressionAttributeValues = attrValues;
  }

  const items = [];
  let lastKey;
  do {
    if (lastKey) params.ExclusiveStartKey = lastKey;
    const result = await getDdbClient().send(new ScanCommand(params));
    if (result.Items) items.push(...result.Items);
    lastKey = result.LastEvaluatedKey;
  } while (lastKey && items.length < limit);

  return items;
}
