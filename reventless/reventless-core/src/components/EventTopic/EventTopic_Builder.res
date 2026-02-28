module Make = (Spec: Reventless.EventTopic.T, Publisher: EventTopic_Adapter.Publisher): (
  EventTopic.T with module Spec = Spec
) => {
  module Spec = Spec

  type publish = EventTopic.publish<Spec.Id.t, Spec.event>
  type operations = {
    publish: publish,
    publishJson: EventTopic.publishJson,
    publishJsonStream: EventTopic.publishJsonStream,
  }

  type component = Component.t<EventTopic.t, EventTopic.outputs, operations>

  let construct = (~storageResources, self, name) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let publisher = Publisher.make(
      ~name=name->ComponentType.name(EventTopic.componentType),
      ~storageResources,
      ~opts,
    )

    self->Component.setOperations(
      (publisher.publishJson, publisher.publishJsonStream)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((publishJson, publishJsonStream)) => {
        module Operations = EventTopic_Operations.Make(
          Spec,
          {
            let publishJson = publishJson
          },
        )
        {
          publishJson,
          publish: Operations.publish,
          publishJsonStream: publishJsonStream,
        }
      }),
    )

    let outputs: EventTopic.outputs = {resources: publisher.resources}
    self->Component.setOutputs(outputs)
  }

  let make = (~name, ~storageResources, ~opts=?): component =>
    Component.make(
      ~componentType=EventTopic.componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~storageResources, ...),
      ~opts,
    )
}
