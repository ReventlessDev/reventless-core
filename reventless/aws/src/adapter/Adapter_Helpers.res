// SQS queue ARN is `arn:aws:sqs:<region>:<accountId>:<name>` — segment index 4
// (0-based). Used to scope queue-policy service principals to this account via
// the aws:SourceAccount condition key.
let accountIdOfQueueArn = (queueArn: string) =>
  queueArn->String.split(":")->Array.get(4)->Option.getOr("")

let dynamoDbStreamResources = eventTopicResources =>
  eventTopicResources->ReventlessCore.Util.Adapter.filterSupportedResolvedResources([
    AWS.DynamoDbStream.service,
  ])
let snsResources = resources =>
  resources->ReventlessCore.Util.Adapter.filterSupportedResolvedResources([
    AWS.SNS.service,
    AWS.SNS_FIFO.service,
  ])
let sqsResources = resources =>
  resources->ReventlessCore.Util.Adapter.filterSupportedResolvedResources([
    AWS.SQS.service,
    AWS.SQS_FIFO.service,
  ])
let dynamoDbResources = resources =>
  resources->ReventlessCore.Util.Adapter.filterSupportedResolvedResources([
    AWS.DynamoDb.service,
    AWS.DynamoDbStream.service,
  ])
