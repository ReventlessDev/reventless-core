let queryDbOfReadModel: ReadModel.outputs => QueryDb.outputs = readModel => readModel["queryDb"]

let allResolversMakers: array<ReadModel.outputs> => array<
  QueryDb.resolversResourcesMaker,
> = readModels =>
  readModels
  ->Belt.Array.map(queryDbOfReadModel)
  ->Belt.Array.map(queryDb => queryDb["resolversMaker"])
