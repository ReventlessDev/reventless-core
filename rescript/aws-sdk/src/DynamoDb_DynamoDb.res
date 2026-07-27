/*** @aws-sdk/client-dynamodb
  see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/dynamodb/
  
  Use this client to modify (existing) tables.

  ## difference of dynamodb-client vs document-client
    - dynamodb-client 
      - Operates on tables via commands
      - Modification of table via dynamo-db-client update
    - document-client 
      - Operates on the table content (documents), but not on the tables themselves
*/
type client

type options = {
  region?: string,
  maxAttempts?: int,
  requestHandler?: NodeHttpHandler.t,
}

module Raw = {
  @module("@aws-sdk/client-dynamodb") @new
  external client: (~options: options=?, unit) => client = "DynamoDBClient"
}

let clientInstance = ref(None)

/** create a DynamoDBClient with default values:
  - maxAttempts: 3,
  - connectionTimeout: 1000ms
  - requestTimeout: 5000ms

  use `Raw.client` if you want to set alternative configuration
*/
let client: unit => client = () =>
  switch clientInstance.contents {
  | None =>
    let client = Raw.client(
      ~options={
        maxAttempts: 3,
        requestHandler: NodeHttpHandler.make({
          connectionTimeout: 1000,
          requestTimeout: 5000,
        }),
      },
      (),
    )
    clientInstance := Some(client)
    client
  | Some(client) => client
  }

module DescribeTableCommand = {
  /*** describe an existing table — used to read its KeySchema so a truncate can
  build a delete key from each scanned item.

  this command is not available in document-client

  see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/dynamodb/command/DescribeTableCommand/ */

  type t

  type keySchemaElement = {
    @as("AttributeName") attributeName: string,
    /** "HASH" (partition key) or "RANGE" (sort key) */
    @as("KeyType")
    keyType: string,
  }

  /** only the fields a truncate needs; the real description carries far more */
  type tableDescription = {
    @as("TableName") tableName?: string,
    @as("KeySchema") keySchema?: array<keySchemaElement>,
    /** DynamoDB's own approximate row count (updated ~every 6h) */
    @as("ItemCount")
    itemCount?: float,
  }

  type input = {@as("TableName") tableName: string}

  type output = {
    @as("$metadata") metadata: Metadata.t,
    @as("Table") table?: tableDescription,
  }

  @new @module("@aws-sdk/client-dynamodb")
  external make: input => t = "DescribeTableCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

module UpdateTableCommand = {
  /*** modify an existing table

  this command is not available in document-client

  see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/dynamodb/command/UpdateTableCommand/ */

  type t

  type billingMode = [
    | #PROVISIONED
    | #PAY_PER_REQUEST
  ]

  type streamViewType = [
    | #KEYS_ONLY
    | #NEW_IMAGE
    | #OLD_IMAGE
    | #NEW_AND_OLD_IMAGES
  ]
  type streamSpecification = {
    @as("StreamEnabled") streamEnabled: bool,
    @as("StreamViewType")
    streamViewType?: streamViewType,
  }

  /** the following properties have no bindings yet:
    - AttributeDefinitions
    - DeletionProtectionEnabled
    - GlobalSecondaryIndexUpdates
    - OnDemandThroughput
    - ProvisionedThroughput
    - ReplicaUpdates
    - SSESpecification
    - TableClass
  */
  type input = {
    @as("TableName") tableName: string,
    @as("BillingMode") billingMode?: billingMode,
    @as("StreamSpecification") streamSpecification?: streamSpecification,
  }

  type tableDescription = {
    @as("StreamSpecification") streamSpecification: streamSpecification,
    @as("LatestStreamArn") latestStreamArn: string,
    @as("LatestStreamLabel") latestStreamLabel: string,
  }
  type output = {
    @as("$metadata") metadata: Metadata.t,
    @as("TableDescription") tableDescription: tableDescription,
  }

  @new @module("@aws-sdk/client-dynamodb")
  external make: input => t = "UpdateTableCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

module UpdateTimeToLiveCommand = {
  /*** modify ttl config of an existing table

  this command is not available in document-client
  */

  type t

  type timeToLiveSpecification = {
    @as("Enabled") enabled: bool,
    @as("AttributeName") attributeName: string,
  }

  type input = {
    @as("TableName") tableName: string,
    @as("TimeToLiveSpecification") timeToLiveSpecification: timeToLiveSpecification,
  }

  type output = {
    @as("metadata") metadata: Metadata.t,
    @as("TimeToLiveSpecification") timeToLiveSpecification: timeToLiveSpecification,
  }

  @new @module("@aws-sdk/client-dynamodb")
  external make: input => t = "UpdateTimeToLiveCommand"
  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }
  let send: t => promise<output> = command => Raw.send(client(), command)
}

module UpdateContinuousBackupsCommand = {
  /*** modify continuous backup config of an existing table

  this command is not available in document-client
  */

  type t

  type pointInTimeRecoverySpecification = {
    @as("PointInTimeRecoveryEnabled") pointInTimeRecoveryEnabled: bool,
  }
  type input = {
    @as("TableName") tableName: string,
    @as("PointInTimeRecoverySpecification")
    pointInTimeRecoverySpecification: pointInTimeRecoverySpecification,
  }

  type continuousBackupsStatus = [#ENABLED | #DISABLED]
  type pointInTimeRecoveryDescription = {
    @as("EarliestRestorableDateTime") earliestRestorableDateTime?: Date.t,
    @as("PointInTimeRecoveryStatus") pointInTimeRecoveryStatus?: string,
    @as("LatestRestorableDateTime") latestRestorableDateTime?: Date.t,
  }
  type continuousBackupsDescription = {
    @as("ContinuousBackupsStatus") continuousBackupsStatus: continuousBackupsStatus,
    @as("PointInTimeRecoveryDescription")
    pointInTimeRecoveryDescription?: pointInTimeRecoveryDescription,
  }
  type output = {
    @as("$metadata") metadata: Metadata.t,
    @as("ContinuousBackupsDescription") continuousBackupsDescription: continuousBackupsDescription,
  }

  @new @module("@aws-sdk/client-dynamodb")
  external make: input => t = "UpdateContinuousBackupsCommand"
  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}
