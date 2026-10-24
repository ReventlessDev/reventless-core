// InboundTranslationSlice_Builder (AWS)
// Wires AWS adapters and delegates to the core ReventlessCore.InboundTranslationSlice_Builder.

module Make = (
  Api: {
    let api: unit => Types.AppSync.api
    let apiRole: unit => Types.AppSync.role
  },
) => {
  // The deployed slice runs in the shared DCB command Lambda, which builds its
  // own callback and is handed no capabilities; this in-process path answers the
  // same, so the two cannot differ. A spec that declares a need is refused below.
  module Inner = ReventlessCore.InboundTranslationSlice_Builder.Make(
    QueryDbStorage.DynamoDb,
    QueryDbResolvers.AppSync,
    Api,
    {
      let capabilities = () => Reventless.Capabilities.none
    },
  )

  module Make = (
    Spec: Reventless.InboundTranslationSlice.Spec,
    Translation: Reventless.InboundTranslationSlice.Translation with module Spec := Spec,
  ): (ReventlessCore.InboundTranslationSlice.T with module Spec = Spec) => {
    // Refused rather than deployed to fail quietly: the DCB command Lambda this
    // slice runs in has neither the capability settings nor the grants the
    // automation Lambda gets, so every call would answer `Unavailable` at run
    // time with nothing at deploy time to say why.
    if Spec.capabilityNeeds != [] {
      JsError.throwWithMessage(
        `${Spec.name}: an inbound translation slice that declares capability needs (${Spec.capabilityNeeds
          ->Array.map(Reventless.CapabilityNeed.toString)
          ->Array.join(
            ", ",
          )}) cannot be deployed to AWS yet — the DCB command Lambda it runs in is handed no capabilities. Host it on the local platform.`,
      )
    }
    // Register spec + translation module paths so the shared DCB command Lambda's
    // entry point can import them and route `__inboundTranslation` payloads to this
    // slice's `receive` (mirrors StateChangeSlice_Builder's path registration).
    PluginRuntime_Builder.registerInboundTranslationSliceSpec(
      ~specName=Spec.name,
      ~specPath=Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
      ~translationPath=Util_Bundle.getModuleSpecifier(Translation.moduleUrl),
    )
    switch Spec.endpoint {
    | Some({auth: SignedBody({secret})}) =>
      PluginRuntime_Builder.registerWebhook(~specName=Spec.name, ~secret=Some(secret))
    | Some({auth: Open}) => PluginRuntime_Builder.registerWebhook(~specName=Spec.name, ~secret=None)
    | None => ()
    }
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
        PluginRuntime_Builder.registerInboundAuditTableName(~specName=Spec.name, tableResource.name)
      | None => ()
      }
      component
    }
  }
}
