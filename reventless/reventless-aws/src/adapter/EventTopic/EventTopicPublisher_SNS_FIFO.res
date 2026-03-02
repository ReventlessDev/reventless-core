open PulumiAws

let make: ReventlessCore.EventTopic_Adapter.publisherMaker = (~name, ~storageResources as _, ~opts) => {
  let topic = SNS.Topic.make(
    ~name,
    ~args={
      SNS.Topic.fifoTopic: true->Pulumi.Input.make,
      contentBasedDeduplication: true->Pulumi.Input.make,
      tags: AWS.Tags.make(~name, ReventlessCore.EventTopic.componentType),
    },
    ~opts,
  )

  let runtimeTopicOutput = topic->Util_SNS.toRuntimeTopicOutput

  {
    resources: [topic->Util_SNS_FIFO.toResource],
    publishJson: runtimeTopicOutput->Pulumi.Output.apply(runtimeTopic =>
      EventTopicPublisher_SNS_Runtime.publishFifo(runtimeTopic, ...)
    ),
    publishJsonStream: runtimeTopicOutput->Pulumi.Output.apply(runtimeTopic => {
      let publishJson = EventTopicPublisher_SNS_Runtime.publishFifo(runtimeTopic, ...)
      stream =>
        stream
        ->Stream.grouped(10)
        ->Stream.runForEach(items =>
          Effect.promise(() =>
            items
            ->Array.map(({ReventlessInfra.EventTopic.service, meta, json}) =>
              publishJson(service, meta, json)
            )
            ->Promise.all
            ->Promise.thenResolve(_ => ())
          )
        )
    }),
  }
}
