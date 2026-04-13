/*** @aws-sdk/lib-dynamodbdy
   see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/Package/-aws-sdk-lib-dynamodb/
   
  ## difference of dynamodb-client vs document-client
    - dynamodb-client is able to `send` commands which use attributeValues
    - document-client only provides operations on "documents" (table-data)
      - but not on the tables themselves
    - document-client is able to `send` commands AND has methods (named like the commands) which (both) take js-objects instead of attribute values (and abstracts away un-/marshalling)
 */

type client

/*
# TODO

- documentclient can `client.send(command)` AND call opertaions like `client.put(..)`
  - use method variant for operations
*/

type marshallOptions = {convertEmptyValues: bool}

type unmarshallOptions = {wrapNumbers: bool}

type translateConfig = {
  marshallOptions?: DynamoDb_Util.MarshallOptions.options,
  unmarshallOptions?: DynamoDb_Util.Raw.unmarshallOptions,
}

module Raw = {
  @module("@aws-sdk/lib-dynamodb") @scope("DynamoDBDocumentClient")
  external client: (DynamoDb_DynamoDb.client, translateConfig, unit) => client = "from"
}

let clientInstance = ref(None)

/** create a DynamoDBDocumentClient with default values:
  - maxAttempts: 3,
  - connectionTimeout: 1000ms
  - requestTimeout: 5000ms
  - convertEmptyValues: false

  use `Raw.client` if you want to set alternative configuration
*/
let client = () =>
  switch clientInstance.contents {
  | None =>
    let docClient = DynamoDb_DynamoDb.client()->Raw.client(
      {
        marshallOptions: {
          convertEmptyValues: false,
        },
      },
      (),
    )
    clientInstance := Some(docClient)
    docClient
  | Some(docClient) => docClient
  }

type capacity = {
  @as("ReadCapacityUnits") readCapacityUnits: int,
  @as("WriteCapacityUnits") writeCapacityUnits: int,
  @as("CapacityUnits") capacityUnits: int,
}
type consumedCapacity = {
  @as("TableName") tableName: string,
  @as("CapacityUnits") capacityUnits: int,
  @as("ReadCapacityUnits") readCapacityUnits: int,
  @as("WriteCapacityUnits") writeCapacityUnits: int,
  @as("Table") table: capacity,
  @as("LocalSecondaryIndexes") localSecondaryIndexes: dict<capacity>,
  @as("GlobalSecondaryIndexes") globalSecondaryIndexes: dict<capacity>,
}
type itemCollectionMetric = {
  @as("ItemCollectionKey") itemCollectionKey: JSON.t,
  @as("SizeEstimateRangeGB") sizeEstimateRangeGB: array<float>,
}
type returnConsumedCapacity = [#INDEXES | #TOTAL | #NONE]
type returnItemCollectionMetrics = [#SIZE | #NONE]
type returnValues = [
  | #NONE
  | #ALL_OLD
  | #UPDATED_OLD
  | #ALL_NEW
  | #UPDATED_NEW
]

type returnValuesOnConditionCheckFailure = [#NONE | #ALL_OLD]

type select = [
  /** Returns all of the item attributes from the specified table or index. If you query a local secondary index, then for each matching item in the index, DynamoDB fetches the entire item from the parent table. If the index is configured to project all item attributes, then all of the data can be obtained from the local secondary index, and no fetching is required. */
  | #ALL_ATTRIBUTES
  /** Allowed only when querying an index. Retrieves all attributes that have been projected into the index. If the index is configured to project all attributes, this return value is equivalent to specifying ALL_ATTRIBUTES. */
  | #ALL_PROJECTED_ATTRIBUTES
  /** Returns the number of matching items, rather than the matching items themselves. Note that this uses the same quantity of read capacity units as getting the items, and is subject to the same item size calculations. */
  | #COUNT
  /** Returns only the attributes listed in ProjectionExpression. This return value is equivalent to specifying ProjectionExpression without specifying any value for Select. */
  | #SPECIFIC_ATTRIBUTES
]

let getIntAttribute = (attributes: option<dict<JSON.t>>, name: string) => {
  attributes->Option.flatMap(attribute =>
    attribute
    ->Dict.get(name)
    ->Option.flatMap(value => value->JSON.Decode.float)
    ->Option.map(number => number->Int.fromFloat)
  )
}

module PutCommand = {
  type t

  /** see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/Package/-aws-sdk-lib-dynamodb/TypeAlias/PutCommandInput/
  and: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/dynamodb/command/PutItemCommand/

  attributes without bindings yet:
  - ConditionalOperator
  - Expected
  */
  type input = {
    @as("Item")
    item: JSON.t,
    @as("TableName") tableName: string,
    @as("ConditionExpression") conditionExpression?: string,
    @as("ExpressionAttributeNames") expressionAttributeNames?: dict<string>,
    /** this is actually a js object (key/value pairs)*/
    @as("ExpressionAttributeValues")
    expressionAttributeValues?: dict<JSON.t>,
    @as("ReturnConsumedCapacity") returnConsumedCapacity?: returnConsumedCapacity,
    @as("ReturnItemCollectionMetrics") returnItemCollectionMetrics?: returnItemCollectionMetrics,
    @as("ReturnValues") returnValues?: returnValues,
    @as("ReturnValuesOnConditionCheckFailure")
    returnValuesOnConditionCheckFailure?: returnValuesOnConditionCheckFailure,
  }

  type output = {
    @as("$metadata") metadata: Metadata.t,
    @as("Attributes") attributes?: JSON.t,
    @as("ConsumedCapacity") consumedCapacity?: consumedCapacity,
    @as("ItemCollectionMetrics") itemCollectionMetrics?: itemCollectionMetric,
  }

  @new @module("@aws-sdk/lib-dynamodb")
  external make: input => t = "PutCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = input => Raw.send(client(), input)
}

/** send individual put requests for any item
  `batchWrite` can not use `conditionExpression`s
*/
let putMany = (tableName, conditionalExpression, items) => {
  items
  ->Array.map(item => {
    open PutCommand
    {
      PutCommand.tableName,
      item,
      conditionExpression: conditionalExpression,
    }
    ->make
    ->send
  })
  ->Promise.all // FIXME: use allSettled (otherwise the first rejection in the array, will "cancel" out all others
}

/** send put request with a default conditionExpression */
let putIfNotExists = (tableName, idKey, sortKey: option<Nullable.t<string>>, item) => {
  open PutCommand
  {
    PutCommand.item,
    tableName,
    conditionExpression: switch sortKey {
    | Some(Value(sortKey)) => `attribute_not_exists(${idKey}) and attribute_not_exists(${sortKey})`
    | _ => `attribute_not_exists(${idKey})`
    },
  }
  ->make
  ->send
}

module PutError = {
  /*** see throws section in: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/dynamodb/command/PutItemCommand/ */

  module ConditionCheckFailedException = {
    let name = "ConditionalCheckFailedException"
    /** see:
      - https://github.com/smithy-lang/smithy-typescript/blob/75e0125c8d25c4b1002f39d9d0fac7792acc3d43/packages/types/src/http.ts#L33
      - https://github.com/smithy-lang/smithy-typescript/blob/75e0125c8d25c4b1002f39d9d0fac7792acc3d43/packages/types/src/http.ts#L43
    */
    type response = {
      headers: dict<string>,
      statusCode: int,
      body: unknown,
    }
    /** see: https://github.com/smithy-lang/smithy-typescript/blob/75e0125c8d25c4b1002f39d9d0fac7792acc3d43/packages/types/src/shapes.ts#L30 */
    type retryable = {throttling?: bool}
    /* TODO: extract to dynamoDBServiceException type
      this enables you to use type coercion (https://rescript-lang.org/docs/manual/latest/record#record-type-coercion) to transform any of the concretely type records to dynamoDBServiceException
      e.g.
      ```rescript
        let exn: ConditionCheckFailedException.t = <exn>
        let coercedExn: dynamoDBServiceException = <exn> :> dynamoDBServiceException
      ```
 */
    type t = {
      /** `="client"` */
      @as("$fault")
      fault: string, // TODO: extract to `DynamoDBServiceException` type and spread this type
      @as("$metadata")
      metadata: Metadata.t, // TODO: extract to `DynamoDBServiceException` type and spread this type
      @as("$response")
      response?: response, // TODO: extract to `DynamoDBServiceException` type and spread this type
      @as("$retryable")
      retryable?: retryable, // TODO: extract to `DynamoDBServiceException` type and spread this type
      // this must be an object!
      @as("Item")
      item: JSON.t,
      /** `ConditionalCheckFailedException` */
      name: string,
    }

    external ofJsExn: JsExn.t => t = "%identity"
  }

  module InternalServerError = {
    let name = "InternalServerError"
    type t

    external ofJsExn: JsExn.t => t = "%identity"
  }

  module InvalidEndpointException = {
    let name = "InvalidEndpointException"
    type t

    external ofJsExn: JsExn.t => t = "%identity"
  }

  module ItemCollectionSizeLimitExceededException = {
    let name = "ItemCollectionSizeLimitExceededException"
    type t

    external ofJsExn: JsExn.t => t = "%identity"
  }

  module ProvisionedThroughputExceededException = {
    let name = "ProvisionedThroughputExceededException"
    type t

    external ofJsExn: JsExn.t => t = "%identity"
  }

  module RequestLimitExceeded = {
    let name = "RequestLimitExceeded"
    type t

    external ofJsExn: JsExn.t => t = "%identity"
  }

  module ResourceNotFoundException = {
    let name = "ResourceNotFoundException"
    type t

    external ofJsExn: JsExn.t => t = "%identity"
  }

  module TransactionConflictException = {
    let name = "TransactionConflictException"
    type t

    external ofJsExn: JsExn.t => t = "%identity"
  }

  module DynamoDBServiceException = {
    let name = "DynamoDBServiceException"
    type t

    external ofJsExn: JsExn.t => t = "%identity"
  }

  type t =
    | ConditionCheckFailedException(ConditionCheckFailedException.t)
    | InternalServerError(InternalServerError.t)
    | InvalidEndpointException(InvalidEndpointException.t)
    | ItemCollectionSizeLimitExceededException(ItemCollectionSizeLimitExceededException.t)
    | ProvisionedThroughputExceededException(ProvisionedThroughputExceededException.t)
    | RequestLimitExceeded(RequestLimitExceeded.t)
    | ResourceNotFoundException(ResourceNotFoundException.t)
    | TransactionConflictException(TransactionConflictException.t)
    | DynamoDBServiceException(DynamoDBServiceException.t)
    | Unknown(JsExn.t)

  let classify: JsExn.t => t = exn => {
    let name = exn->JsExn.name->Option.getOr("")
    if name == ConditionCheckFailedException.name {
      ConditionCheckFailedException(exn->ConditionCheckFailedException.ofJsExn)
    } else if name == InternalServerError.name {
      InternalServerError(exn->InternalServerError.ofJsExn)
    } else if name == InvalidEndpointException.name {
      InvalidEndpointException(exn->InvalidEndpointException.ofJsExn)
    } else if name == ItemCollectionSizeLimitExceededException.name {
      ItemCollectionSizeLimitExceededException(
        exn->ItemCollectionSizeLimitExceededException.ofJsExn,
      )
    } else if name == ProvisionedThroughputExceededException.name {
      ProvisionedThroughputExceededException(exn->ProvisionedThroughputExceededException.ofJsExn)
    } else if name == RequestLimitExceeded.name {
      RequestLimitExceeded(exn->RequestLimitExceeded.ofJsExn)
    } else if name == ResourceNotFoundException.name {
      ResourceNotFoundException(exn->ResourceNotFoundException.ofJsExn)
    } else if name == TransactionConflictException.name {
      TransactionConflictException(exn->TransactionConflictException.ofJsExn)
    } else if name == DynamoDBServiceException.name {
      DynamoDBServiceException(exn->DynamoDBServiceException.ofJsExn)
    } else {
      Unknown(exn)
    }
  }
}

module BatchWriteCommand = {
  /*** see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/dynamodb/command/BatchWriteItemCommand/ */

  type t

  type putRequest = {
    /** A map of attribute name to attribute values, representing the primary key of an item to be processed by PutItem. All of the table's primary key attributes must be specified, and their data types must match those of the table's key schema. If any attributes are present in the item that are part of an index key schema for the table, their types must match the index key schema.

    this must be an object!
    */
    @as("Item")
    item: JSON.t,
  }
  type deleteRequest = {
    /** A map of attribute name to attribute values, representing the primary key of the item to delete. All of the table's primary key attributes must be specified, and their data types must match those of the table's key schema.
    note: this uses JSON.t to have a single type for any value
    note: JSON.t is _not_ the json stringified value!

    */
    @as("Key")
    key: dict<JSON.t>,
  }
  /** use either putRequest _or_ deleteRequest: both being set will result in a runtime error!
  TODO: `@as` is not supported in rescript v10 -> use following code, when rescript v11 is used:
  NOTE: this will result in an object having a TAG property of either "Put" or "Delete" _additionally_ to either "putRequest" or "deleteRequest" field
  type writeRequest =
  | Put({@as("PutRequest") putRequest: putRequest})
  | Delete({@as("DeleteRequest") deleteRequest: deleteRequest})
  */
  type writeRequest = {
    @as("PutRequest") putRequest?: putRequest,
    @as("DeleteRequest") deleteRequest?: deleteRequest,
  }

  /** see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/Package/-aws-sdk-client-dynamodb/Interface/BatchWriteItemCommandInput */
  type input = {
    /** map of table name to Requests */
    @as("RequestItems")
    requestItems: dict<array<writeRequest>>, // TODO: model max batch size of 25 in type system
    @as("ReturnConsumedCapacity") returnConsumedCapacity?: returnConsumedCapacity,
    @as("ReturnItemCollectionMetrics") returnItemCollectionMetrics?: returnItemCollectionMetrics,
  }

  /** see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/Package/-aws-sdk-lib-dynamodb/TypeAlias/BatchWriteCommandOutput/
  and: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/Package/-aws-sdk-client-dynamodb/Interface/BatchWriteItemCommandOutput/
  */
  type output = {
    @as("$metadata") metadata: Metadata.t,
    @as("ConsumedCapacity") consumedCapacity?: array<consumedCapacity>,
    @as("ItemCollectionMetrics") itemCollectionMetrics?: dict<array<itemCollectionMetric>>,
    @as("UnprocessedItems") unprocessedItems?: dict<array<writeRequest>>,
  }

  @new @module("@aws-sdk/lib-dynamodb")
  external make: input => t = "BatchWriteCommand"

  let maxBatchSize = 25

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  /** batchWrite: max. batch size is 25 */
  let send: t => promise<output> = input => Raw.send(client(), input)
}

module UpdateCommand = {
  /*** see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/dynamodb/command/UpdateItemCommand/ */

  type t

  /** see: https://github.com/aws/aws-sdk-js-v3/blob/de4dc495455a47cd718c635209cd7aef9167797c/clients/client-dynamodb/src/models/models_0.ts#L11460 */
  type input = {
    /** The primary key of the item to be updated. Each element consists of an attribute name and a value for that attribute.

    For the primary key, you must provide all of the attributes. For example, with a simple primary key, you only need to provide a value for the partition key. For a composite primary key, you must provide values for both the partition key and the sort key.
    */
    @as("Key")
    key: dict<JSON.t>,
    /** The name of the table containing the item to update. You can also provide the Amazon Resource Name (ARN) of the table in this parameter. */
    @as("TableName")
    tableName: string,
    /** A condition that must be satisfied in order for a conditional update to succeed. */
    @as("ConditionExpression")
    conditionExpression?: string, // TODO: implemend a functional interface to create valid conditionExpressions (aka SDL or builder pattern)
    /** One or more substitution tokens for attribute names in an expression. */
    @as("ExpressionAttributeNames")
    expressionAttributeNames?: dict<string>,
    /** One or more values that can be substituted in an expression. */
    @as("ExpressionAttributeValues")
    expressionAttributeValues?: dict<JSON.t>,
    /** Determines the level of detail about either provisioned or on-demand throughput consumption that is returned in the response */
    @as("ReturnConsumedCapacity")
    returnConsumedCapacity?: returnConsumedCapacity,
    /** Determines whether item collection metrics are returned. */
    @as("ReturnItemCollectionMetrics")
    returnItemCollectionMetrics?: returnItemCollectionMetrics,
    /** Use ReturnValues if you want to get the item attributes as they appear before or after they are successfully updated. */
    @as("ReturnValues")
    returnValues?: returnValues,
    /** An optional parameter that returns the item attributes for an UpdateItem operation that failed a condition check. */
    @as("ReturnValuesOnConditionCheckFailure")
    returnValuesOnConditionCheckFailure?: returnValuesOnConditionCheckFailure,
    /** An expression that defines one or more attributes to be updated, the action to be performed on them, and new values for them. */
    @as("UpdateExpression")
    updateExpression?: string, // TODO: implemend a functional interface to create valid updateExpressions (aka SDL or builder pattern)
  }

  type output = {
    @as("$metadata") metadata: Metadata.t,
    /** A map of attribute values as they appear before or after the UpdateItem operation, as determined by the ReturnValues parameter.*/
    @as("Attributes")
    attributes?: dict<JSON.t>,
    @as("ConsumedCapacity") consumedCapacity?: consumedCapacity,
    @as("ItemCollectionMetrics") itemCollectionMetrics?: itemCollectionMetric,
  }

  @new @module("@aws-sdk/lib-dynamodb")
  external make: input => t = "UpdateCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = input => Raw.send(client(), input)
}

module DeleteCommand = {
  /*** see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/Package/-aws-sdk-lib-dynamodb/Class/DeleteCommand/ */

  type t

  type input = {
    /** The name of the table from which to delete the item. You can also provide the Amazon Resource Name (ARN) of the table in this parameter. */
    @as("TableName")
    tableName: string,
    /** A map of attribute names to values, representing the primary key of the item to delete. */
    @as("Key")
    key: dict<JSON.t>,
    /** A condition that must be satisfied in order for a conditional DeleteItem to succeed. */
    @as("ConditionExpression")
    conditionExpression?: string,
    /** One or more substitution tokens for attribute names in an expression. */
    @as("ExpressionAttributeNames")
    expressionAttributeNames?: dict<string>,
    /** One or more values that can be substituted in an expression. */
    @as("ExpressionAttributeValues")
    expressionAttributeValues?: dict<JSON.t>,
    /** Determines the level of detail about either provisioned or on-demand throughput consumption that is returned in the response. */
    @as("ReturnConsumedCapacity")
    returnConsumedCapacity?: returnConsumedCapacity,
    /** Determines whether item collection metrics are returned. If set to SIZE, the response includes statistics about item collections, if any, that were modified during the operation are returned in the response. */
    @as("ReturnItemCollectionMetrics")
    returnItemCollectionMetrics?: returnItemCollectionMetrics,
    /** Use ReturnValues if you want to get the item attributes as they appeared before they were deleted. */
    @as("ReturnValues")
    returnValues?: returnValues,
    /** An optional parameter that returns the item attributes for a DeleteItem operation that failed a condition check. */
    @as("ReturnValuesOnConditionCheckFailure")
    returnValuesOnConditionCheckFailure?: returnValuesOnConditionCheckFailure,
  }

  type output = {
    @as("$metadata") metadata: Metadata.t,
    /** A map of attribute names to values, representing the item as it appeared before the DeleteItem operation. This map appears in the response only if ReturnValues was specified as ALL_OLD in the request. */
    @as("Attributes")
    attributes?: dict<JSON.t>,
    /** The capacity units consumed by the DeleteItem operation. The data returned includes the total provisioned throughput consumed, along with statistics for the table and any indexes involved in the operation. ConsumedCapacity is only returned if the ReturnConsumedCapacity parameter was specified. For more information, see Provisioned capacity mode 
in the Amazon DynamoDB Developer Guide. */
    @as("ConsumedCapacity")
    consumedCapacity?: consumedCapacity,
    /** Information about item collections, if any, that were affected by the DeleteItem operation. ItemCollectionMetrics is only returned if the ReturnItemCollectionMetrics parameter was specified. */
    @as("ItemCollectionMetrics")
    itemCollectionMetrics?: itemCollectionMetric,
  }

  @new @module("@aws-sdk/lib-dynamodb")
  external make: input => t = "DeleteCommand"
  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }
  let send: t => promise<output> = command => {
    Raw.send(client(), command)
  }
}

let deleteById: (~tableName: string, ~id: string) => promise<DeleteCommand.output> = (
  ~tableName,
  ~id,
) => {
  open DeleteCommand
  {
    DeleteCommand.tableName,
    key: [("id", id->JSON.Encode.string)]->Dict.fromArray,
  }
  ->make
  ->send
}

let deleteByIdSort: (
  ~tableName: string,
  ~id: string,
  ~sortField: string,
  ~sortKey: string,
) => promise<DeleteCommand.output> = (~tableName, ~id, ~sortField, ~sortKey) => {
  let keyDict =
    [("id", id->JSON.Encode.string), (sortField, sortKey->JSON.Encode.string)]->Dict.fromArray
  open DeleteCommand
  {
    DeleteCommand.tableName,
    key: keyDict,
  }
  ->make
  ->send
}

let delete: (
  ~sort: (string, string)=?,
  ~tableName: string,
  ~id: string,
) => promise<DeleteCommand.output> = (~sort=?, ~tableName, ~id) =>
  switch sort {
  | Some((sortField, sortKey)) => deleteByIdSort(~tableName, ~id, ~sortField, ~sortKey)
  | None => deleteById(~tableName, ~id)
  }

module TransactWriteCommand = {
  /*** see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/Package/-aws-sdk-lib-dynamodb/Class/TransactWriteCommand/ */

  type t

  type conditionCheck = {
    /** The primary key of the item to be checked. Each element consists of an attribute name and a value for that attribute. */
    @as("Key")
    key: dict<JSON.t>,
    /** Name of the table for the check item request. You can also provide the Amazon Resource Name (ARN) of the table in this parameter. */
    @as("TableName")
    tableName: string,
    /** A condition that must be satisfied in order for a conditional update to succeed. */
    @as("ConditionExpression")
    conditionExpression: string,
    /** One or more substitution tokens for attribute names in an expression.  */
    @as("ExpressionAttributeNames")
    expressionAttributeNames?: dict<string>,
    /* One or more values that can be substituted in an expression. */
    @as("ExpressionAttributeValues") expressionAttributeValues?: dict<JSON.t>,
    /** Use ReturnValuesOnConditionCheckFailure to get the item attributes if the ConditionCheck condition fails. */
    @as("ReturnValuesOnConditionCheckFailure")
    returnValuesOnConditionCheckFailure?: returnValuesOnConditionCheckFailure,
  }

  type delete = {
    /** The primary key of the item to be deleted. Each element consists of an attribute name and a value for that attribute. */
    @as("Key")
    key: dict<JSON.t>,
    /** Name of the table in which the item to be deleted resides. You can also provide the Amazon Resource Name (ARN) of the table in this parameter. */
    @as("TableName")
    tableName: string,
    /** A condition that must be satisfied in order for a conditional delete to succeed. */
    @as("ConditionExpression")
    conditionExpression?: string,
    /** One or more substitution tokens for attribute names in an expression. */
    @as("ExpressionAttributeNames)")
    expressionAttributeNames?: dict<string>,
    /** One or more values that can be substituted in an expression. */
    @as("ExpressionAttributeValues")
    expressionAttributeValues?: dict<JSON.t>,
    /** Use ReturnValuesOnConditionCheckFailure to get the item attributes if the Delete condition fails. */
    @as("ReturnValuesOnConditionCheckFailure")
    returnValuesOnConditionCheckFailure?: returnValuesOnConditionCheckFailure,
  }

  type put = {
    /** A map of attribute name to attribute values, representing the primary key of the item to be written by PutItem. All of the table's primary key attributes must be specified, and their data types must match those of the table's key schema. If any attributes are present in the item that are part of an index key schema for the table, their types must match the index key schema.

    this must be an object!
    */
    @as("Item")
    item: JSON.t,
    /** Name of the table in which to write the item. You can also provide the Amazon Resource Name (ARN) of the table in this parameter. */
    @as("TableName")
    tableName: string,
    /** A condition that must be satisfied in order for a conditional update to succeed. */
    @as("ConditionExpression")
    conditionExpression?: string,
    /** One or more substitution tokens for attribute names in an expression. */
    @as("ExpressionAttributeNames")
    expressionAttributeNames?: dict<string>,
    /** One or more values that can be substituted in an expression. */
    @as("ExpressionAttributeValues")
    expressionAttributeValues?: dict<JSON.t>,
    /** se ReturnValuesOnConditionCheckFailure to get the item attributes if the Put condition fails. */
    @as("ReturnValuesOnConditionCheckFailure")
    returnValuesOnConditionCheckFailure?: returnValuesOnConditionCheckFailure,
  }

  type update = {
    /** The primary key of the item to be updated. Each element consists of an attribute name and a value for that attribute. */
    @as("Key")
    key: dict<JSON.t>,
    /** Name of the table for the UpdateItem request. You can also provide the Amazon Resource Name (ARN) of the table in this parameter. */
    @as("TableName")
    tableName: string,
    /** An expression that defines one or more attributes to be updated, the action to be performed on them, and new value(s) for them. */
    @as("UpdateExpression")
    updateExpression: string,
    /** A condition that must be satisfied in order for a conditional update to succeed. */
    @as("ConditionExpression")
    conditionExpression?: string,
    /** One or more substitution tokens for attribute names in an expression. */
    @as("ExpressionAttributeNames")
    expressionAttributeNames?: dict<string>,
    /** One or more values that can be substituted in an expression. */
    @as("ExpressionAttributeValues")
    expressionAttributeValues?: dict<JSON.t>,
    /** Use ReturnValuesOnConditionCheckFailure to get the item attributes if the Update condition fails. */
    @as("ReturnValuesOnConditionCheckFailure")
    returnValuesOnConditionCheckFailure?: returnValuesOnConditionCheckFailure,
  }

  type transactWriteItem = {
    /** A request to perform a check item operation. */
    @as("ConditionCheck")
    conditionCheck?: conditionCheck,
    /** A request to perform a DeleteItem operation. */
    @as("Delete")
    delete?: delete,
    /** A request to perform a PutItem operation. */
    @as("Put")
    put?: put,
    /** A request to perform an UpdateItem operation. */
    @as("Update")
    update?: update,
  }

  type input = {
    /** An ordered array of up to 100 TransactWriteItem objects, each of which contains a ConditionCheck, Put, Update, or Delete object. These can operate on items in different tables, but the tables must reside in the same Amazon Web Services account and Region, and no two of them can operate on the same item.  */
    @as("TransactItems")
    transactItems: array<transactWriteItem>,
    /** Providing a ClientRequestToken makes the call to TransactWriteItems idempotent, meaning that multiple identical calls have the same effect as one single call. */
    @as("ClientRequestToken")
    clientRequestToken?: string,
    /** Determines the level of detail about either provisioned or on-demand throughput consumption that is returned in the response. */
    @as("ReturnConsumedCapacity")
    returnConsumedCapacity?: returnConsumedCapacity,
    /** Determines whether item collection metrics are returned. If set to SIZE, the response includes statistics about item collections (if any), that were modified during the operation and are returned in the response. If set to NONE (the default), no statistics are returned. */
    @as("ReturnItemCollectionMetrics")
    returnItemCollectionMetrics?: returnItemCollectionMetrics,
  }

  type output = {
    @as("$metadata") metadata: Metadata.t,
    /** The capacity units consumed by the entire TransactWriteItems operation. The values of the list are ordered according to the ordering of the TransactItems request parameter. */
    @as("ConsumedCapacity")
    consumedCapacity?: array<consumedCapacity>,
    /** A list of tables that were processed by TransactWriteItems and, for each table, information about any item collections that were affected by individual UpdateItem, PutItem, or DeleteItem operations.  */
    @as("ItemCollectionMetrics")
    itemCollectionMetrics?: dict<array<itemCollectionMetric>>,
  }

  @new @module("@aws-sdk/lib-dynamodb")
  external make: input => t = "TransactWriteCommand"

  module Raw = {
    @send
    external send: (client, input) => promise<output> = "send"
  }
  let send = command => {
    Raw.send(client(), command)
  }
}

module QueryCommand = {
  /*** see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/Package/-aws-sdk-lib-dynamodb/Class/QueryCommand/ */

  type t

  type input = {
    /** The name of the table containing the requested items. You can also provide the Amazon Resource Name (ARN) of the table in this parameter. */
    @as("TableName")
    tableName: string,
    /** Determines the read consistency model: If set to true, then the operation uses strongly consistent reads; otherwise, the operation uses eventually consistent reads.
    Strongly consistent reads are not supported on global secondary indexes. If you query a global secondary index with ConsistentRead set to true, you will receive a ValidationException. */
    @as("ConsistentRead")
    consistentRead?: bool,
    /** The primary key of the first item that this operation will evaluate. Use the value that was returned for LastEvaluatedKey in the previous operation.
    The data type for ExclusiveStartKey must be String, Number, or Binary. No set data types are allowed. */
    @as("ExclusiveStartKey")
    exclusiveStartKey?: dict<JSON.t>,
    /** One or more substitution tokens for attribute names in an expression. */
    @as("ExpressionAttributeNames")
    expressionAttributeNames?: dict<string>,
    /** One or more values that can be substituted in an expression. */
    @as("ExpressionAttributeValues")
    expressionAttributeValues?: dict<JSON.t>,
    /** A string that contains conditions that DynamoDB applies after the Query operation, but before the data is returned to you. Items that do not satisfy the FilterExpression criteria are not returned.
    A FilterExpression does not allow key attributes. You cannot define a filter expression based on a partition key or a sort key.
    A FilterExpression is applied after the items have already been read; the process of filtering does not consume any additional read capacity units. */
    @as("FilterExpression")
    filterExpression?: string,
    /** The name of an index to query. This index can be any local secondary index or global secondary index on the table. Note that if you use the IndexName parameter, you must also provide TableName. */
    @as("IndexName")
    indexName?: string,
    /** he condition that specifies the key values for items to be retrieved by the Query action.
    The condition must perform an equality test on a single partition key value. */
    @as("KeyConditionExpression")
    keyConditionExpression?: string,
    /** The maximum number of items to evaluate (not necessarily the number of matching items). If DynamoDB processes the number of items up to the limit while processing the results, it stops the operation and returns the matching values up to that point, and a key in LastEvaluatedKey to apply in a subsequent operation, so that you can pick up where you left off. Also, if the processed dataset size exceeds 1 MB before DynamoDB reaches this limit, it stops the operation and returns the matching values up to the limit, and a key in LastEvaluatedKey to apply in a subsequent operation to continue the operation. */
    @as("Limit")
    limit?: int,
    /** A string that identifies one or more attributes to retrieve from the table. These attributes can include scalars, sets, or elements of a JSON document. The attributes in the expression must be separated by commas.
    If no attribute names are specified, then all attributes will be returned. If any of the requested attributes are not found, they will not appear in the result. */
    @as("ProjectionExpression")
    projectionExpression?: string,
    /** Determines the level of detail about either provisioned or on-demand throughput consumption that is returned in the response. */
    @as("ReturnConsumedCapacity")
    returnConsumedCapacity?: returnConsumedCapacity,
    /** Specifies the order for index traversal: If true (default), the traversal is performed in ascending order; if false, the traversal is performed in descending order. */
    @as("ScanIndexForward")
    scanIndexForward?: bool,
    /** The attributes to be returned in the result. You can retrieve all item attributes, specific item attributes, the count of matching items, or in the case of an index, some or all of the attributes projected into the index. */
    @as("Select")
    select?: select,
  }

  type output = {
    @as("$metadata") metadata: Metadata.t,
    /** The capacity units consumed by the Query operation. The data returned includes the total provisioned throughput consumed, along with statistics for the table and any indexes involved in the operation. ConsumedCapacity is only returned if the ReturnConsumedCapacity parameter was specified. */
    @as("ConsumedCapacity")
    consumedCapacity?: consumedCapacity,
    /** The number of items in the response.
    If you used a QueryFilter in the request, then Count is the number of items returned after the filter was applied, and ScannedCount is the number of matching items before the filter was applied.
    If you did not use a filter in the request, then Count and ScannedCount are the same. */
    @as("Count")
    count?: int,
    /** An array of item attributes that match the query criteria. Each element in this array consists of an attribute name and the value for that attribute.

    this data type is an array of objects.
    */
    @as("Items")
    items?: array<JSON.t>,
    /** The primary key of the item where the operation stopped, inclusive of the previous result set. Use this value to start a new operation, excluding this value in the new request.
    If LastEvaluatedKey is empty, then the "last page" of results has been processed and there is no more data to be retrieved.
    If LastEvaluatedKey is not empty, it does not necessarily mean that there is more data in the result set. The only way to know when you have reached the end of the result set is when LastEvaluatedKey is empty. */
    @as("LastEvaluatedKey")
    lastEvaluatedKey?: dict<JSON.t>,
    /** The number of items evaluated, before any QueryFilter is applied. A high ScannedCount value with few, or no, Count results indicates an inefficient Query operation.
    If you did not use a filter in the request, then ScannedCount is the same as Count. */
    @as("ScannedCount")
    scannedCount?: int,
  }

  @new @module("@aws-sdk/lib-dynamodb")
  external make: input => t = "QueryCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

module GetCommand = {
  /*** see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/Package/-aws-sdk-lib-dynamodb/Class/GetCommand/ */

  type t

  type input = {
    @as("TableName")
    tableName: string,
    @as("Key")
    key: dict<JSON.t>,
    @as("ConsistentRead")
    consistentRead?: bool,
    @as("ExpressionAttributeNames")
    expressionAttributeNames?: dict<string>,
    @as("ProjectionExpression")
    projectionExpression?: string,
    @as("ReturnConsumedCapacity")
    returnConsumedCapacity?: returnConsumedCapacity,
  }

  type output = {
    @as("$metadata") metadata: Metadata.t,
    @as("Item") item?: JSON.t,
    @as("ConsumedCapacity") consumedCapacity?: consumedCapacity,
  }

  @new @module("@aws-sdk/lib-dynamodb")
  external make: input => t = "GetCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}


module ScanCommand = {
  /*** see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/Package/-aws-sdk-lib-dynamodb/Class/ScanCommand/ */

  type t

  type input = {
    /** The name of the table containing the requested items or if you provide IndexName, the name of the table to which that index belongs.
    You can also provide the Amazon Resource Name (ARN) of the table in this parameter. */
    @as("TableName")
    tableName: string,
    /** A Boolean value that determines the read consistency model during the scan. */
    @as("ConsistentRead")
    consistentRead?: bool,
    /** The primary key of the first item that this operation will evaluate. Use the value that was returned for LastEvaluatedKey in the previous operation.
    The data type for ExclusiveStartKey must be String, Number or Binary. No set data types are allowed. */
    @as("ExclusiveStartKey")
    exclusiveStartKey?: dict<JSON.t>,
    /** One or more substitution tokens for attribute names in an expression. */
    @as("ExpressionAttributeNames")
    expressionAttributeNames?: dict<string>,
    /** One or more values that can be substituted in an expression. */
    @as("ExpressionAttributeValues")
    expressionAttributeValues?: dict<JSON.t>,
    /** A string that contains conditions that DynamoDB applies after the Scan operation, but before the data is returned to you. Items that do not satisfy the FilterExpression criteria are not returned.
    A FilterExpression is applied after the items have already been read; the process of filtering does not consume any additional read capacity units. */
    @as("FilterExpression")
    filterExpression?: string,
    /** The name of a secondary index to scan. This index can be any local secondary index or global secondary index. Note that if you use the IndexName parameter, you must also provide TableName. */
    @as("IndexName")
    indexName?: string,
    /** The maximum number of items to evaluate (not necessarily the number of matching items). If DynamoDB processes the number of items up to the limit while processing the results, it stops the operation and returns the matching values up to that point, and a key in LastEvaluatedKey to apply in a subsequent operation, so that you can pick up where you left off. Also, if the processed dataset size exceeds 1 MB before DynamoDB reaches this limit, it stops the operation and returns the matching values up to the limit, and a key in LastEvaluatedKey to apply in a subsequent operation to continue the operation. */
    @as("Limit")
    limit?: int,
    /** A string that identifies one or more attributes to retrieve from the specified table or index. These attributes can include scalars, sets, or elements of a JSON document. The attributes in the expression must be separated by commas.
    If no attribute names are specified, then all attributes will be returned. If any of the requested attributes are not found, they will not appear in the result. */
    @as("ProjectionExpression")
    projectionExpression?: string,
    /** Determines the level of detail about either provisioned or on-demand throughput consumption that is returned in the response. */
    @as("ReturnConsumedCapacity")
    returnConsumedCapacity?: returnConsumedCapacity,
    /** For a parallel Scan request, Segment identifies an individual segment to be scanned by an application worker.
    Segment IDs are zero-based, so the first segment is always 0. For example, if you want to use four application threads to scan a table or an index, then the first thread specifies a Segment value of 0, the second thread specifies 1, and so on.
    The value of LastEvaluatedKey returned from a parallel Scan request must be used as ExclusiveStartKey with the same segment ID in a subsequent Scan operation.
    The value for Segment must be greater than or equal to 0, and less than the value provided for TotalSegments.
    If you provide Segment, you must also provide TotalSegments. */
    @as("Segment")
    segment?: int,
    /** The attributes to be returned in the result. You can retrieve all item attributes, specific item attributes, the count of matching items, or in the case of an index, some or all of the attributes projected into the index. */
    @as("Select")
    select?: select,
    /** For a parallel Scan request, TotalSegments represents the total number of segments into which the Scan operation will be divided. The value of TotalSegments corresponds to the number of application workers that will perform the parallel scan. For example, if you want to use four application threads to scan a table or an index, specify a TotalSegments value of 4.
    The value for TotalSegments must be greater than or equal to 1, and less than or equal to 1000000. If you specify a TotalSegments value of 1, the Scan operation will be sequential rather than parallel.
    If you specify TotalSegments, you must also specify Segment. */
    @as("TotalSegments")
    totalSegments?: int,
  }

  type output = QueryCommand.output

  @new @module("@aws-sdk/lib-dynamodb")
  external make: input => t = "ScanCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

