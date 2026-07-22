module Make = (
  Spec: ReventlessInfra.EventLog.T,
  Storage: EventLog_Adapter.Storage,
  EventTopicPublisher: EventTopic_Adapter.Publisher,
): (EventLog.T with module Spec = Spec) => {
  module Spec = Spec

  type operations = {
    append: EventLog.append<Spec.Id.t, Message.event'<Spec.Id.t, Spec.event>>,
    replay: EventLog.replay<Spec.Id.t, Spec.event>,
    replayStream: EventLog.replayStream<Spec.Id.t, Spec.event>,
    appendStream: EventLog.appendStream<Spec.Id.t, Spec.event>,
    latestSnapshot: EventLog.latestSnapshot<Spec.Id.t>,
    writeSnapshot: EventLog.writeSnapshot<Spec.Id.t>,
  }
  type component = Component.t<EventLog.t, EventLog.outputs, operations>

  let construct = (~owner=?, self, name) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let storage = Storage.make(
      ~name=name->ComponentType.name(EventLog.componentType),
      ~owner?,
      ~opts,
    )

    module SpecificEventTopic = EventTopic_Builder.Make(Spec, EventTopicPublisher)
    let eventTopic = SpecificEventTopic.make(
      ~name,
      ~storageResources=storage.resources,
      ~owner?,
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
          replayStream: Ops.replayStream,
          appendStream: Ops.appendStream,
          latestSnapshot: Ops.latestSnapshot,
          writeSnapshot: Ops.writeSnapshot,
        }
      }),
    )

    let outputs: EventLog.outputs = {
      resources: storage.resources,
      eventTopic: eventTopic->Component.outputs,
    }
    self->Component.setOutputs(outputs)
  }

  let make = (~name, ~owner=?, ~opts=?): component =>
    Component.make(
      ~componentType=EventLog.componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~owner?, ...),
      ~opts,
    )
}
