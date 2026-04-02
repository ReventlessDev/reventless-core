/** Bindings for @aws-appsync/utils and AppSync JS resolver context types.
    Used in resolver source files compiled to APPSYNC_JS — not Pulumi deploy-time code.

    Generated JS uses `import * as X from "@aws-appsync/utils"` which is equivalent to
    the named-import form `import { util, runtime } from "@aws-appsync/utils"` since
    AppSync provides the module as an object with named exports. When bundled with
    esbuild (--external:@aws-appsync/utils), the import is preserved for AppSync runtime.
*/

// ---------------------------------------------------------------------------
// Context types
// ---------------------------------------------------------------------------

type error = {
  message: string,
  @as("type") type_: string,
}

type cognitoIdentity = {
  username: string,
  sub: string,
  sourceIp: array<string>,
  claims: Dict.t<JSON.t>,
}

type info = {
  fieldName: string,
  parentTypeName: string,
}

/** AppSync JS resolver context object. 'args, 'source and 'result are parametric. */
type ctx<'args, 'source, 'result> = {
  args: 'args,
  identity: cognitoIdentity,
  result: 'result,
  source: 'source,
  error: Nullable.t<error>,
  info: info,
  stash: Dict.t<JSON.t>,
}

// ---------------------------------------------------------------------------
// DynamoDB attribute types
// ---------------------------------------------------------------------------

/** Opaque DynamoDB typed attribute value (e.g. {S: "foo"}, {N: "42"}, {BOOL: true}). */
type dynamoDbValue

/** A map of DynamoDB attribute values — used in keys, attributeValues, etc. */
type dynamoDbMap = Dict.t<dynamoDbValue>

// ---------------------------------------------------------------------------
// @aws-appsync/utils — util.dynamodb.*
// ---------------------------------------------------------------------------

module DynamoDB = {
  /** Auto-detect type and convert a JS value to a DynamoDB attribute value.
      Equivalent to VTL's $util.dynamodb.toDynamoDBJson(val). */
  @module("@aws-appsync/utils") @scope(("util", "dynamodb"))
  external toDynamoDB: 'a => dynamoDbValue = "toDynamoDB"

  @module("@aws-appsync/utils") @scope(("util", "dynamodb"))
  external toString: string => dynamoDbValue = "toString"

  @module("@aws-appsync/utils") @scope(("util", "dynamodb"))
  external toNumber: float => dynamoDbValue = "toNumber"

  @module("@aws-appsync/utils") @scope(("util", "dynamodb"))
  external toBoolean: bool => dynamoDbValue = "toBoolean"

  @module("@aws-appsync/utils") @scope(("util", "dynamodb"))
  external toNull: unit => dynamoDbValue = "toNull"

  @module("@aws-appsync/utils") @scope(("util", "dynamodb"))
  external toList: array<dynamoDbValue> => dynamoDbValue = "toList"

  /** Convert a plain JS object's values to DynamoDB attribute values. */
  @module("@aws-appsync/utils") @scope(("util", "dynamodb"))
  external toMapValues: {..} => dynamoDbMap = "toMapValues"

  @module("@aws-appsync/utils") @scope(("util", "dynamodb"))
  external toStringSet: array<string> => dynamoDbValue = "toStringSet"

  @module("@aws-appsync/utils") @scope(("util", "dynamodb"))
  external toNumberSet: array<float> => dynamoDbValue = "toNumberSet"
}

// ---------------------------------------------------------------------------
// @aws-appsync/utils — util.*
// ---------------------------------------------------------------------------

module Util = {
  /** Throw a resolver error. Calling this terminates the resolver. */
  @module("@aws-appsync/utils") @scope("util")
  external error: (string, ~errorType: string=?) => 'a = "error"

  /** Throw an unauthorized error. Calling this terminates the resolver. */
  @module("@aws-appsync/utils") @scope("util")
  external unauthorized: unit => 'a = "unauthorized"

  @module("@aws-appsync/utils") @scope("util")
  external defaultIfNull: (Nullable.t<'a>, 'a) => 'a = "defaultIfNull"

  @module("@aws-appsync/utils") @scope("util")
  external defaultIfNullOrBlank: (Nullable.t<string>, string) => string = "defaultIfNullOrBlank"

  @module("@aws-appsync/utils") @scope("util")
  external isNull: Nullable.t<'a> => bool = "isNull"

  @module("@aws-appsync/utils") @scope("util")
  external isNullOrBlank: Nullable.t<string> => bool = "isNullOrBlank"

  @module("@aws-appsync/utils") @scope("util")
  external isList: 'a => bool = "isList"
}

// ---------------------------------------------------------------------------
// @aws-appsync/utils — runtime.*
// ---------------------------------------------------------------------------

module Runtime = {
  /** Return a value early from a resolver pipeline function, skipping remaining functions. */
  @module("@aws-appsync/utils") @scope("runtime")
  external earlyReturn: 'a => 'b = "earlyReturn"
}

// ---------------------------------------------------------------------------
// DynamoDB request helpers (typed record shapes accepted by AppSync)
// ---------------------------------------------------------------------------

type expressionQuery = {
  expression: string,
  expressionNames: Dict.t<string>,
  expressionValues: dynamoDbMap,
}

type expressionFilter = {
  expression: string,
  expressionNames: Dict.t<string>,
  expressionValues: dynamoDbMap,
}

type getItemRequest = {
  operation: string,
  key: dynamoDbMap,
}

type queryRequest = {
  operation: string,
  query: expressionQuery,
  index?: string,
  limit?: int,
  nextToken?: Nullable.t<string>,
  scanIndexForward?: bool,
  filter?: expressionFilter,
}

type putItemRequest = {
  operation: string,
  key: dynamoDbMap,
  attributeValues: dynamoDbMap,
}

type updateItemRequest = {
  operation: string,
  key: dynamoDbMap,
  update: {
    expression: string,
    expressionNames: Dict.t<string>,
    expressionValues: dynamoDbMap,
  },
}

type deleteItemRequest = {
  operation: string,
  key: dynamoDbMap,
}

type batchGetItemTable = {
  keys: array<dynamoDbMap>,
  consistentRead: bool,
}

type batchGetItemRequest = {
  operation: string,
  tables: Dict.t<batchGetItemTable>,
}

type scanRequest = {
  operation: string,
  limit?: int,
  nextToken?: Nullable.t<string>,
}

type lambdaRequest = {
  operation: string,
  payload: JSON.t,
}

// ---------------------------------------------------------------------------
// DynamoDB result helpers
// ---------------------------------------------------------------------------

/** Result shape from a DynamoDB Query or Scan operation. */
type queryResult<'item> = {
  items: array<'item>,
  nextToken: Nullable.t<string>,
  scannedCount: int,
}

/** Result shape from a DynamoDB BatchGetItem operation. */
type batchGetItemResult<'item> = {
  data: Dict.t<array<'item>>,
}
