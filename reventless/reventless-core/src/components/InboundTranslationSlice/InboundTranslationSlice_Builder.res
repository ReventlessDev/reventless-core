// InboundTranslationSlice builder — creates the audit log QueryDb and wires
// the receive function that translates external input into domain commands.
//
// Simpler than OutboundTranslationSlice — no EventCollector needed.
// Triggered externally via operations.receive rather than by event subscription.

module Make = (
  QueryDbStorage: QueryDb_Adapter.Storage,
  QueryDbResolvers: QueryDb_Adapter.Resolvers
    with type api = QueryDbStorage.api
    and type role = QueryDbStorage.role,
  Api: {
    let api: unit => QueryDbStorage.api
    let apiRole: unit => QueryDbStorage.role
  },
) => {
  module Make = (Spec: Reventless.InboundTranslationSlice.MergedSpec): (
    InboundTranslationSlice.T with module Spec = Spec
  ) => {
    module Spec = Spec
    type component = InboundTranslationSlice.component

    module Callback = InboundTranslationSlice_Callback.Make(Spec)

    let queryDbName = Spec.name ++ "Audit"

    // QueryDb for audit log — stores auditRow keyed by request ID
    module AuditQueryDbSpec = {
      module Id = Reventless.Id.String
      let name = queryDbName
      let moduleUrl: string = %raw(`import.meta.url`)
      type state = InboundTranslationSlice_Callback.auditRow
      let stateSchema = InboundTranslationSlice_Callback.auditRowSchema
      let config = Reventless.ReadModel.config()
      let subIdConfig: option<Reventless.ReadModel.subIdConfig<state>> = None
    }

    module SpecificQueryDb = QueryDb_Builder.Make(AuditQueryDbSpec, QueryDbStorage, QueryDbResolvers)

    let syncToQueryDb = async (queryDbOps: SpecificQueryDb.operations) => {
      let items = Callback.auditLog->Dict.toArray
      let _ = await items->Array.reduce(Promise.resolve(), async (prev, (id, row)) => {
        let _ = await prev
        let _ = await queryDbOps.save(
          id->Reventless.Id.String.makeFromString,
          row,
          QueryDb.Overwrite,
          None,
        )
      })
    }

    let construct = (~publishJsons, self, _name) => {
      let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

      let queryDb = SpecificQueryDb.make(~api=Api.api(), ~apiRole=Api.apiRole(), ~opts)

      // Resolve publishJsons so it's available for receive
      let publishJsonsRef: ref<option<ReventlessInfra.CommandTopic.publishJsons>> = ref(None)
      let _ = publishJsons->Pulumi.Output.apply(pj => {
        publishJsonsRef := Some(pj)
      })

      self->Component.setOperations(
        (queryDb->Component.operations, publishJsons)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((queryDbOps, publishJsonsFn)) => {
          let ops: InboundTranslationSlice.operations = {
            receive: async inputJson => {
              let result = await Callback.receive(publishJsonsFn, inputJson)
              await syncToQueryDb(queryDbOps)
              result
            },
          }
          ops
        }),
      )

      let outputs: InboundTranslationSlice.outputs = {
        resources: [],
        queryDb: queryDb->Component.outputs,
      }
      self->Component.setOutputs(outputs)
    }

    let make = (~publishJsons, ~opts=?): InboundTranslationSlice.component =>
      Component.make(
        ~componentType=InboundTranslationSlice.componentType->ComponentType.toString,
        ~name=Spec.name,
        ~construct=construct(~publishJsons, ...),
        ~opts,
      )
  }
}
