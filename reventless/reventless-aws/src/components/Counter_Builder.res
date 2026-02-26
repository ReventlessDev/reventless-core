module Make = (Api: {
  let api: Types.AppSync.api
  let apiRole: Types.AppSync.role
}) => ReventlessCore.Counter_Builder.Make(
  QueryDbStorage_DynamoDbStream,
  Api,
  CounterHandler_DynamoDbStream,
)
