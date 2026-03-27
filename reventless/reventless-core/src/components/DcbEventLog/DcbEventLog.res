let componentType = ComponentType.DcbEventLog

type outputs = ReventlessInfra.DcbEventLog.outputs

type t = ReventlessInfra.DcbEventLog.t

type rawEvent = ReventlessInfra.DcbEventLog.rawEvent
type rawSequencedEvent = ReventlessInfra.DcbEventLog.rawSequencedEvent
type readResult = ReventlessInfra.DcbEventLog.readResult
type read = ReventlessInfra.DcbEventLog.read
type append = ReventlessInfra.DcbEventLog.append
type readStream = ReventlessInfra.DcbEventLog.readStream
type appendStream = ReventlessInfra.DcbEventLog.appendStream
type operations = ReventlessInfra.DcbEventLog.operations
type component = ReventlessInfra.DcbEventLog.component

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
  type component = component

  let make: (
    ~name: string,
    ~indexes: array<string>=?,
    ~partitionTag: Reventless.DcbTag.partitionTag,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
