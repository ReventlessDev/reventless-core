module Make = (
  Api: {
    let api: unit => Types.AppSync.api
    let apiRole: unit => Types.AppSync.role
  },
) => ReventlessCore.Counter_Builder.Make(
  QueryDbStorage_DynamoDbStream,
  Api,
  CounterHandler_DynamoDbStream,
)
