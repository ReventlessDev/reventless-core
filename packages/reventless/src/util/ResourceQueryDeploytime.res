let queryDbOfReadModel: ReventlessSpec.ReadModel.outputs => ReventlessSpec.QueryDb.outputs = readModel => readModel["queryDb"]

let allResolversMakers: array<ReventlessSpec.ReadModel.outputs> => array<
  ReventlessSpec.QueryDb.resolversResourcesMaker,
> = readModels =>
  readModels
  ->Belt.Array.map(queryDbOfReadModel)
  ->Belt.Array.map(queryDb => queryDb["resolversMaker"])
