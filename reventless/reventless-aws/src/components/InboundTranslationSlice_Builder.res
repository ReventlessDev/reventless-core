// InboundTranslationSlice_Builder (AWS)
// Wires AWS adapters and delegates to the core ReventlessCore.InboundTranslationSlice_Builder.

module Make = (Api: {
  let api: unit => Types.AppSync.api
  let apiRole: unit => Types.AppSync.role
}) => ReventlessCore.InboundTranslationSlice_Builder.Make(
  QueryDbStorage.DynamoDb,
  QueryDbResolvers.AppSync,
  Api,
)
