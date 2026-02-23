let dynamoDbStreamResources = eventTopicResources =>
  eventTopicResources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
    AWS.DynamoDbStream.service,
  ])
let snsResources = resources =>
  resources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
    AWS.SNS.service,
    AWS.SNS_FIFO.service,
  ])
let sqsResources = resources =>
  resources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
    AWS.SQS.service,
    AWS.SQS_FIFO.service,
  ])
let dynamoDbResources = resources =>
  resources->Reventless.Util.Adapter.filterSupportedUnwrappedResources([
    AWS.DynamoDb.service,
    AWS.DynamoDbStream.service,
  ])
