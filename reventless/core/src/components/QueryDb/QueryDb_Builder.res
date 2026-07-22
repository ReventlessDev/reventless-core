module Make = (
  Spec: Reventless.ReadModel.Spec,
  Storage: QueryDb_Adapter.Storage,
  Resolvers: QueryDb_Adapter.Resolvers with type api = Storage.api and type role = Storage.role,
): (QueryDb.T with module Spec = Spec and type api = Storage.api and type role = Storage.role) => {
  module Spec = Spec

  type api = Storage.api
  type role = Storage.role
  type operations = QueryDb.operations<Spec.Id.t, Spec.state>
  type component = Component.t<QueryDb.t, QueryDb.outputs, operations>

  let construct = (self, name, ~api, ~apiRole, ~ttl=?, ~owner=?) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let subIdField = Spec.subIdConfig->Option.map(config => config.subIdField)

    let storage = Storage.make(
      ~name,
      ~indexes=Spec.config.indexes,
      ~subIdField?,
      ~ttl?,
      ~api,
      ~apiRole,
      ~owner?,
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
          loadStream: Operations.loadStream,
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
      ~authorization=Spec.authorization,
      ~opts,
    )

    let outputs: QueryDb.outputs = {
      resources: storage.resources->Array.concat(resolvers.resources),
      resolversMaker: resolvers.resourcesMaker,
      dataSourceName: storage.dataSourceName,
    }
    self->Component.setOutputs(outputs)
  }

  let make = (~api: Storage.api, ~apiRole: Storage.role, ~ttl=?, ~owner=?, ~opts=?): component =>
    Component.make(
      ~componentType=QueryDb.componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~api, ~apiRole, ~ttl?, ~owner?, ...),
      ~opts,
    )
}
