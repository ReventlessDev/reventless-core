type streamViewType =
  | KEYS_ONLY
  | NEW_IMAGE
  | OLD_IMAGE
  | NEW_AND_OLD_IMAGES

type keys = {id: AwsSdk.DynamoDb.Util.attributeValue}
type image = dict<AwsSdk.DynamoDb.Util.attributeValue>

type streamRecord = {
  @as("ApproximateCreationTime") approximateCreationTime?: int,
  @as("Keys") keys: keys,
  @as("NewImage") newImage?: image,
  @as("OldImage") oldImage?: image,
  @as("SequenceNumber") sequenceNumber?: string,
  @as("SizeBytes") sizeBytes?: int,
  @as("StreamViewType") streamViewType?: streamViewType,
}

type functionResponseType =
  | INSERT
  | MODIFY
  | REMOVE

type record = {
  awsRegion: string,
  dynamodb?: streamRecord,
  eventID: string,
  eventName: functionResponseType,
  eventSource: string,
  eventSourceARN: string,
  eventVersion: string,
  userIdentity: string,
}

external asRecord: Lambda.CallbackFunction.record => record = "%identity"

type event = {@as("Records") records: array<record>}

type itemIdentifier = {itemIdentifier: string}
type streamEventResponse = {batchItemFailures: array<itemIdentifier>}
