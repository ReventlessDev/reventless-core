// InboundTranslationSlice_Builder (AWS)
// Wires AWS adapters and delegates to the core ReventlessCore.InboundTranslationSlice_Builder.

module Make = (Api: {
  let api: unit => Types.AppSync.api
  let apiRole: unit => Types.AppSync.role
}) => {
  module Inner = ReventlessCore.InboundTranslationSlice_Builder.Make(
    QueryDbStorage.DynamoDb,
    QueryDbResolvers.AppSync,
    Api,
  )

  module Make = (
    Spec: Reventless.InboundTranslationSlice.Spec,
    Translation: Reventless.InboundTranslationSlice.Translation with module Spec := Spec,
  ): (ReventlessCore.InboundTranslationSlice.T with module Spec = Spec) => {
    // Register spec + translation module paths so the shared DCB command Lambda's
    // entry point can import them and route `__inboundTranslation` payloads to this
    // slice's `receive` (mirrors StateChangeSlice_Builder's path registration).
    PluginRuntime_Builder.registerInboundTranslationSliceSpec(
      ~specName=Spec.name,
      ~specPath=Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
      ~translationPath=Util_Bundle.getModuleSpecifier(Translation.moduleUrl),
    )
    module InnerMake = Inner.Make(Spec, Translation)
    module Spec = Spec
    module Translation = Translation
    type component = InnerMake.component
    let queryDbName = InnerMake.queryDbName

    let make = (~publishJsons, ~runtime=?, ~opts=?) => {
      let component = InnerMake.make(~publishJsons, ~runtime?, ~opts?)
      // The audit QueryDb's physical table name is Pulumi-generated, so it can only
      // be read off the constructed component's outputs (resolved synchronously here,
      // before forDcbCommandTopic builds HANDLER_CONFIG). Thread it so the entry
      // point's Route 0 can persist the audit rows the in-process path writes inline.
      let outputs: ReventlessInfra.InboundTranslationSlice.outputs =
        component->ReventlessCore.Component.outputs
      switch outputs.queryDb.resources->Array.get(0) {
      | Some(tableResource) =>
        PluginRuntime_Builder.registerInboundAuditTableName(
          ~specName=Spec.name,
          tableResource.name,
        )
      | None => ()
      }
      component
    }
  }
}
