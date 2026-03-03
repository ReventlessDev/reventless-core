// InboundTranslationSlice_Builder (AWS)
// Wires AWS adapters and delegates to the core ReventlessCore.InboundTranslationSlice_Builder.

module Make = (Api: {
  let api: Types.AppSync.api
  let apiRole: Types.AppSync.role
}) => ReventlessCore.InboundTranslationSlice_Builder.Make(
  QueryDbStorage.DynamoDb,
  QueryDbResolvers.AppSync,
  Api,
)
