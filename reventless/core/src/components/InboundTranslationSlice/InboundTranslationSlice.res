let componentType = ComponentType.InboundTranslationSlice

type t = ReventlessInfra.InboundTranslationSlice.t
type outputs = ReventlessInfra.InboundTranslationSlice.outputs
type operations = ReventlessInfra.InboundTranslationSlice.operations
type acceptedResult = ReventlessInfra.InboundTranslationSlice.acceptedResult
type rejectedResult = ReventlessInfra.InboundTranslationSlice.rejectedResult
type component = Component.t<t, outputs, operations>

let toResolvedOutputs = (outputs: outputs): Pulumi.Output.t<
  ReventlessInterop.InboundTranslationSlice.resolvedOutputs,
> =>
  (
    outputs.resources->Adapter.resourcesToInterop,
    outputs.queryDb.resources->Adapter.resourcesToInterop,
  )
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((resources, queryDbResources)) => {
    let resolved: ReventlessInterop.InboundTranslationSlice.resolvedOutputs = {
      resources,
      queryDb: {resources: queryDbResources},
    }
    resolved
  })

module type T = {
  module Spec: Reventless.InboundTranslationSlice.Spec
  module Translation: Reventless.InboundTranslationSlice.Translation with module Spec := Spec
  type component = Component.t<t, outputs, operations>
  let queryDbName: string

  let make: (
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    /** The target's publish that waits for each command's outcome, where its topic
        offers one; the caller then hears the target's refusal. */
    ~publishJsonsAndWait: Pulumi.Output.t<option<CommandTopic.publishJsonsAndWait>>=?,
    ~runtime: ReventlessInfra.RuntimeHints.t=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
