module Make = (Spec: ReventlessSpec.EventTopic.T, Publisher: EventTopic_Adapter.Publisher): (
  EventTopic.T with module Spec = Spec
) => {
  module Spec = Spec

  type publish = EventTopic.publish<Spec.Id.t, Spec.event>
  type operations = {publish: publish, publishJson: EventTopic.publishJson}

  type component = Component.t<EventTopic.t, EventTopic.outputs, operations>

  let construct = (~storageResources, self, name) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let publisher = Publisher.make(
      ~name=name->ComponentType.name(EventTopic.componentType),
      ~storageResources,
      ~opts,
    )

    self->Component.setOperations(
      publisher.publishJson->Pulumi.Output.apply(publishJson => {
        module Operations = EventTopic_Operations.Make(
          Spec,
          {
            let publishJson = publishJson
          },
        )
        {
          publishJson,
          publish: Operations.publish,
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
