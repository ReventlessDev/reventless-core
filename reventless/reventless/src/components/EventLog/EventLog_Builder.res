module Make = (
  Spec: ReventlessSpec.EventLog.T,
  Storage: EventLog_Adapter.Storage,
  EventTopicPublisher: EventTopic_Adapter.Publisher,
): (EventLog.T with module Spec = Spec) => {
  module Spec = Spec

  type operations = {
    append: EventLog.append<Spec.Id.t, Message.event'<Spec.Id.t, Spec.event>>,
    replay: EventLog.replay<Spec.Id.t, Spec.event>,
  }
  type component = Component.t<EventLog.t, EventLog.outputs, operations>

  let construct = (self, name) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let storage = Storage.make(~name=name->ComponentType.name(EventLog.componentType), ~opts)

    module SpecificEventTopic = EventTopic_Builder.Make(Spec, EventTopicPublisher)
    let eventTopic = SpecificEventTopic.make(
      ~name,
      ~storageResources=storage.resources,
      ~opts=opts->Util.Pulumi.ComponentResourceOptions.ofCustomResourceOptions,
    )

    self->Component.setOperations(
      (storage.operations, eventTopic->Component.operations)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((storageOps, eventTopicOps)) => {
        module Ops = EventLog_Operations.Make(
          Spec,
          {
            module Spec = Spec
            module EventTopic = SpecificEventTopic
            let eventTopic = eventTopicOps
            let storage = storageOps
          },
        )

        {
          append: Ops.append,
          replay: Ops.replay,
        }
      }),
    )

    let outputs: EventLog.outputs = {
      resources: storage.resources,
      eventTopic: eventTopic->Component.outputs,
    }
    self->Component.setOutputs(outputs)
  }

  let make = (~name, ~opts=?): component =>
    Component.make(
      ~componentType=EventLog.componentType->ComponentType.toString,
      ~name,
      ~construct,
      ~opts,
    )
}
