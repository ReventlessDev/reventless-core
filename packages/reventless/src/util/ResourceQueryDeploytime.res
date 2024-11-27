let queryDbOfReadModel: ReventlessSpec.ReadModel.outputs => ReventlessSpec.QueryDb.outputs = (
  readModel: ReventlessSpec.ReadModel.outputs,
) => readModel.queryDb

let allResolversMakers: array<ReventlessSpec.ReadModel.outputs> => array<
  ReventlessSpec.QueryDb.resolversResourcesMaker,
> = readModels =>
  readModels
  ->Belt.Array.map(queryDbOfReadModel)
  ->Belt.Array.map(queryDb => queryDb.resolversMaker)
