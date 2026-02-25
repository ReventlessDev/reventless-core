let dynamoDbStreamResources = eventTopicResources =>
  eventTopicResources->Reventless.Util.Adapter.filterSupportedResolvedResources([
    AWS.DynamoDbStream.service,
  ])
let snsResources = resources =>
  resources->Reventless.Util.Adapter.filterSupportedResolvedResources([
    AWS.SNS.service,
    AWS.SNS_FIFO.service,
  ])
let sqsResources = resources =>
  resources->Reventless.Util.Adapter.filterSupportedResolvedResources([
    AWS.SQS.service,
    AWS.SQS_FIFO.service,
  ])
let dynamoDbResources = resources =>
  resources->Reventless.Util.Adapter.filterSupportedResolvedResources([
    AWS.DynamoDb.service,
    AWS.DynamoDbStream.service,
  ])
