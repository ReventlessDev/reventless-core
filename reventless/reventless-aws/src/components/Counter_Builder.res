module Make = (ApiValues: {
  let api: Types.AppSync.api
  let apiRole: Types.AppSync.role
}) => Reventless.Counter_Builder.Make(
  QueryDbStorage_DynamoDbStream,
  ApiValues,
  CounterHandler_DynamoDbStream,
)
