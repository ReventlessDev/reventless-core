let componentType = ComponentType.AutomationSlice

type t = ReventlessInfra.AutomationSlice.t
type outputs = ReventlessInfra.AutomationSlice.outputs
type operations = ReventlessInfra.AutomationSlice.operations
type component = Component.t<t, outputs, operations>

let toResolvedOutputs = (
  outputs: outputs,
): Pulumi.Output.t<ReventlessInterop.AutomationSlice.resolvedOutputs> =>
  (
    outputs.resources->Adapter.resourcesToInterop,
    outputs.queryDb.resources->Adapter.resourcesToInterop,
  )
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((resources, queryDbResources)) => {
    let resolved: ReventlessInterop.AutomationSlice.resolvedOutputs = {
      resources: resources,
      queryDb: {resources: queryDbResources},
    }
    resolved
  })

module type T = {
  module Spec: Reventless.AutomationSlice.Spec
  module Automation: Reventless.AutomationSlice.Automation with module Spec := Spec
  type component = Component.t<t, outputs, operations>
  let queryDbName: string
  /** Names of all sources this slice consumes (deduplicated). Used by
      `Plugin_Builder` for the source-name fail-fast assembly check. */
  let sourceNames: array<string>

  let make: (
    ~allEventTopics: EventTopic.allOutputs,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~context: Reventless.AutomationSlice.context,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
