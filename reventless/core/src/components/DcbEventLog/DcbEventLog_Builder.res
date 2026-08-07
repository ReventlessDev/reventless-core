module Make = (
  Storage: DcbEventLog_Adapter.Storage,
  EventTopicPublisher: EventTopic_Adapter.Publisher,
): DcbEventLog.T => {

  // DcbEventLog uses a generic JSON event topic (no typed event schema needed)
  module EventTopicSpec = {
    module Id = Reventless.Id.String
    let name = "DcbEventLog"
    @schema
    type event = JSON.t
  }

  type component = ReventlessInfra.DcbEventLog.component

  let construct = (indexes, partitionTag, crossPartitionTagKeys, self, name) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let logName = name->ComponentType.name(DcbEventLog.componentType)
    // The DCB event log is shared across the plugin's slices, so the plugin owns
    // it — not any one component.
    let owner: ResourceAttribution.owner = {kind: ComponentType.Plugin, name}
    let storage = Storage.make(
      ~name=logName,
      ~indexes,
      ~partitionTag,
      ~crossPartitionTagKeys,
      ~opts,
    )

    // Announce the log to any registered extension. No-op unless a deploy program
    // registered a backend via EventLogProvisioning.use — see
    // src/adapter/EventLogProvisioning/EventLogProvisioning.res.
    EventLogProvisioning.notify(
      ~logStyle=Dcb,
      ~name=logName,
      ~owner=Some(owner),
      ~resources=storage.resources,
      ~opts,
    )

    module SpecificEventTopic = EventTopic_Builder.Make(EventTopicSpec, EventTopicPublisher)
    let eventTopic = SpecificEventTopic.make(
      ~name,
      ~storageResources=storage.resources,
      ~owner,
      ~opts=opts->Util.Pulumi.ComponentResourceOptions.ofCustomResourceOptions,
    )

    self->Component.setOperations(
      (storage.operations, eventTopic->Component.operations)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((storageOps, eventTopicOps)) => {
        module Ops = DcbEventLog_Operations.Make({
          let name = name
          // Must match the key Plugin_Builder uses to register this DcbEventLog's
          // EventTopic in `allEventTopics` (`name ++ "DcbEventLog"`), so that
          // ReadModel `Mapping.sourceName` matches `meta.service` at dispatch.
          let serviceName = name ++ "DcbEventLog"
          let storage = storageOps
          let publishJson = eventTopicOps.publishJson
        })

        let ops: DcbEventLog.operations = {
          read: Ops.read,
          append: Ops.append,
          readStream: Ops.readStream,
          appendStream: Ops.appendStream,
        }
        ops
      }),
    )

    let outputs: DcbEventLog.outputs = {
      resources: storage.resources,
      eventTopic: eventTopic->Component.outputs,
    }
    self->Component.setOutputs(outputs)
  }

  let make = (~name, ~indexes=[], ~partitionTag, ~crossPartitionTagKeys=[], ~opts=?): component =>
    Component.make(
      ~componentType=DcbEventLog.componentType->ComponentType.toString,
      ~name,
      ~construct=construct(indexes, partitionTag, crossPartitionTagKeys, ...),
      ~opts,
    )
}
