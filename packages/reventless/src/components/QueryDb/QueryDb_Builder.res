module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.ReadModel_Spec.T,
  Storage: QueryDb_Adapter.Storage with type api = Config.api and type role = Config.role,
  Resolvers: QueryDb_Adapter.Resolvers with type api = Config.api and type role = Config.role,
): (QueryDb.T with module Spec = Spec) => {
  module Spec = Spec

  type operations = QueryDb.operations<Spec.Id.t, Spec.state>
  type component = Component.t<QueryDb.t, QueryDb.outputs, operations>

  let construct = (self, name, ~api, ~apiRole, ~ttl=?) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let subIdField = Spec.subIdConfig->Option.map(config => config.subIdField)
    let storageName = name->ComponentType.name(QueryDb.componentType)

    let storage = Storage.make(
      ~name=storageName,
      ~indexes=Spec.config.indexes,
      ~subIdField?,
      ~ttl?,
      ~api,
      ~apiRole,
      ~opts,
    )

    self->Component.setOperations(
      storage.operations->Pulumi.Output.apply(jsonOps => {
        module Operations = QueryDb_Operations.Make(
          Spec,
          {
            let jsonOps = jsonOps
          },
        )
        {
          QueryDb.load: Operations.load,
          save: Operations.save,
          saveBatch: Operations.saveBatch,
          count: Operations.count,
          delete: Operations.delete,
          deleteBatch: Operations.deleteBatch,
        }
      }),
    )

    let resolvers = Resolvers.make(
      ~name,
      ~api,
      ~apiRole,
      ~dataSourceName=storage.dataSourceName,
      ~indexes=Spec.config.indexes,
      ~subIdField,
      ~idResolverConfigs=Spec.config.idResolvers,
      ~idsResolverConfigs=Spec.config.idsResolvers,
      ~opts,
    )

    self->Component.setOutputs({
      QueryDb.resources: storage.resources->Array.concat(resolvers.resources),
      resolversMaker: resolvers.resourcesMaker,
    })
  }

  let make = (~ttl=?, ~opts=?): component =>
    Component.make(
      ~componentType=QueryDb.componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~api=Config.api, ~apiRole=Config.apiRole, ~ttl?, ...),
      ~opts
    )
}
