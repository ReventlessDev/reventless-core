// StateViewSlice_Builder (AWS)
// Wires AWS adapters and delegates to the core ReventlessCore.StateViewSlice_Builder.

module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorRuntimeBuilder = ReventlessCore.EventCollectorRuntime_Builder_Single.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
)

module Make = (ApiValues: {
  let api: Types.AppSync.api
  let apiRole: Types.AppSync.role
}) => ReventlessCore.StateViewSlice_Builder.Make(
  RuntimeEnvironment,
  QueryDbStorage.DynamoDb,
  QueryDbResolvers.AppSync,
  EventCollectorChannel,
  EventCollectorRuntimeBuilder,
  ApiValues,
)
