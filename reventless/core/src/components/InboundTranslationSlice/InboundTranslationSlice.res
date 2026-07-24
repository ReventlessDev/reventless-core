let componentType = ComponentType.InboundTranslationSlice

type t = ReventlessInfra.InboundTranslationSlice.t
type outputs = ReventlessInfra.InboundTranslationSlice.outputs
type operations = ReventlessInfra.InboundTranslationSlice.operations
type acceptedResult = ReventlessInfra.InboundTranslationSlice.acceptedResult
type rejectedResult = ReventlessInfra.InboundTranslationSlice.rejectedResult
type receiveResult = ReventlessInfra.InboundTranslationSlice.receiveResult
type component = Component.t<t, outputs, operations>

/**
Map a `receive` outcome onto the `CommandResult` union the slice's mutation field
declares, so both surfaces feed `CommandTopic.commandOutcomeToJson` rather than
hand-rolling a second `__typename` writer.

A translation can fan out across several targets; the mutation response reports
the first target as `entityId` and the fan-out count as `eventCount`. The
per-target detail stays queryable through the slice's audit read model. When the
translation legitimately produced no command, `entityId` is omitted (encoding as
`null`) rather than reporting a target that does not exist.
*/
let receiveResultToOutcome = (result: receiveResult): CommandTopic.commandOutcome =>
  switch result {
  | Ok({requestId, targetIds, commandCount}) =>
    switch targetIds->Array.get(0) {
    | Some(entityId) => Accepted({msgId: requestId, entityId, eventCount: commandCount})
    | None => Accepted({msgId: requestId, eventCount: commandCount})
    }
  | Error({requestId, error}) =>
    Rejected({msgId: requestId, errorCode: "TranslationFailed", errorDetail: Some(error)})
  }

let toResolvedOutputs = (
  outputs: outputs,
): Pulumi.Output.t<ReventlessInterop.InboundTranslationSlice.resolvedOutputs> =>
  (
    outputs.resources->Adapter.resourcesToInterop,
    outputs.queryDb.resources->Adapter.resourcesToInterop,
  )
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((resources, queryDbResources)) => {
    let resolved: ReventlessInterop.InboundTranslationSlice.resolvedOutputs = {
      resources: resources,
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
    ~runtime: ReventlessInfra.RuntimeHints.t=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
