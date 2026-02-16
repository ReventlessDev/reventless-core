module Make = (
  Spec: DcbEventLog.Spec,
  Storage: DcbEventLog_Adapter.Storage,
  EventTopicPublisher: EventTopic_Adapter.Publisher,
): (DcbEventLog.T with module Spec = Spec) => {
  module Spec = Spec

  // DcbEventLog.Spec has the same shape as EventTopic.Spec minus Id
  // We need an EventTopic.Spec to build the EventTopic
  module EventTopicSpec = {
    module Id = ReventlessSpec.Id.String
    @schema
    type event = Spec.event
  }

  type operations = {
    read: DcbEventLog.read<Spec.event>,
    append: DcbEventLog.append<Spec.event>,
  }
  type component = Component.t<DcbEventLog.t, DcbEventLog.outputs, operations>

  // Extract indexes from event schema
  let indexes: array<string> = {
    let taggedFields = DcbTag.extractTaggedFields(Spec.eventSchema)

    // Create single-tag indexes
    let singleTagIndexes = taggedFields->Array.map(tagKey => `tag_${tagKey}`)

    // Add composite index if there are multiple tagged fields
    let compositeIndex = if taggedFields->Array.length > 1 {
      ["tag_composite"]
    } else {
      []
    }

    Array.concat(singleTagIndexes, compositeIndex)
  }

  let construct = (self, name) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let storage = Storage.make(
      ~name=name->ComponentType.name(DcbEventLog.componentType),
      ~indexes,
      ~opts,
    )

    module SpecificEventTopic = EventTopic_Builder.Make(EventTopicSpec, EventTopicPublisher)
    let eventTopic = SpecificEventTopic.make(
      ~name,
      ~storageResources=storage.resources,
      ~opts=opts->Util.Pulumi.ComponentResourceOptions.ofCustomResourceOptions,
    )

    self->Component.setOperations(
      (storage.operations, eventTopic->Component.operations)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((storageOps, eventTopicOps)) => {
        module Ops = DcbEventLog_Operations.Make(
          Spec,
          {
            module Spec = Spec
            let storage = storageOps
            let publishJson = eventTopicOps.publishJson
          },
        )

        {
          read: Ops.read,
          append: Ops.append,
        }
      }),
    )

    self->Component.setOutputs({
      DcbEventLog.resources: storage.resources,
      eventTopic: eventTopic->Component.outputs,
    })
  }

  let make = (~name, ~opts=?): component =>
    Component.make(
      ~componentType=DcbEventLog.componentType->ComponentType.toString,
      ~name,
      ~construct,
      ~opts,
    )
}
