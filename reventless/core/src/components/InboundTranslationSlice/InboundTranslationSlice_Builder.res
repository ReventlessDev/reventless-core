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
  module Make = (
    Spec: Reventless.InboundTranslationSlice.Spec,
    Translation: Reventless.InboundTranslationSlice.Translation with module Spec := Spec,
  ): InboundTranslationSlice.T => {
    module Spec = Spec
    module Translation = Translation
    type component = InboundTranslationSlice.component

    module Callback = InboundTranslationSlice_Callback.Make(Spec, Translation)

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
      let authorization: Reventless.Authorization.permission = AllowAuthenticated
      let visibility: Reventless.Visibility.t = Public
    }

    module SpecificQueryDb = QueryDb_Builder.Make(AuditQueryDbSpec, QueryDbStorage, QueryDbResolvers)

    // Persist just this request's audit row, taking it out of the in-memory log
    // as it goes — see `takeAuditRow` for why draining the whole dict is wrong.
    let syncToQueryDb = async (queryDbOps: SpecificQueryDb.operations, requestId: string) =>
      switch Callback.auditLog->InboundTranslationSlice_Callback.takeAuditRow(requestId) {
      | Some(row) =>
        let _ = await queryDbOps.save(
          requestId->Reventless.Id.String.makeFromString,
          row,
          QueryDb.Overwrite,
          None,
        )
      | None => ()
      }

    let construct = (~publishJsons, self, _name) => {
      let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

      let queryDb = SpecificQueryDb.make(
        ~api=Api.api(),
        ~apiRole=Api.apiRole(),
        ~owner={kind: ComponentType.InboundTranslationSlice, name: Spec.name},
        ~opts,
      )

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
              await syncToQueryDb(
                queryDbOps,
                result->InboundTranslationSlice_Callback.requestIdOf,
              )
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

    // InboundTranslationSlice publishes commands + syncs its QueryDb inline; it
    // provisions no per-slice runtime environment, so the runtime hint is accepted
    // (for composition-surface parity) and discarded.
    let make = (
      ~publishJsons,
      ~runtime as _=?,
      ~opts=?,
    ): InboundTranslationSlice.component =>
      Component.make(
        ~componentType=InboundTranslationSlice.componentType->ComponentType.toString,
        ~name=Spec.name,
        ~construct=construct(~publishJsons, ...),
        ~opts,
      )
  }
}
