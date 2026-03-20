let componentType = ComponentType.DcbEventLog

type outputs = ReventlessInfra.DcbEventLog.outputs

type t = ReventlessInfra.DcbEventLog.t
type component<'operations> = Component.t<t, outputs, 'operations>

type sequencedEvent<'event> = ReventlessInfra.DcbEventLog.sequencedEvent<'event>
type readResult<'event> = ReventlessInfra.DcbEventLog.readResult<'event>
type read<'event> = ReventlessInfra.DcbEventLog.read<'event>
type append<'event> = ReventlessInfra.DcbEventLog.append<'event>
type readStream<'event> = ReventlessInfra.DcbEventLog.readStream<'event>
type appendStream<'event> = ReventlessInfra.DcbEventLog.appendStream<'event>
type operations<'event> = ReventlessInfra.DcbEventLog.operations<'event>

let toResolvedOutputs = (
  outputs: outputs,
): Pulumi.Output.t<ReventlessInterop.DcbEventLog.resolvedOutputs> =>
  (
    outputs.resources->Adapter.resourcesToInterop,
    outputs.eventTopic.resources->Adapter.resourcesToInterop,
  )
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((resources, eventTopicResources)) => {
    let resolved: ReventlessInterop.DcbEventLog.resolvedOutputs = {
      resources: resources,
      eventTopic: {resources: eventTopicResources},
    }
    resolved
  })

module type T = {
  module Spec: Reventless.DcbEventLog.Spec

  type component = component<operations<Spec.event>>

  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}
