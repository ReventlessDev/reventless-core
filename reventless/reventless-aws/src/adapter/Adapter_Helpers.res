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
