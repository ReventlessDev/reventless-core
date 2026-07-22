open PulumiAws

let make: ReventlessCore.EventTopic_Adapter.publisherMaker = (~name, ~storageResources as _, ~owner as _=?, ~opts) => {
  let tags = AWS.Tags.make(~name, ~kind=ReventlessCore.EventTopic.componentType, ~role=EventTopic)
  let topic = SNS.Topic.make(
    ~name,
    ~args={
      SNS.Topic.fifoTopic: true->Pulumi.Input.make,
      contentBasedDeduplication: true->Pulumi.Input.make,
      tags,
    },
    ~opts,
  )

  let resolvedTopicOutput = topic->Util_SNS.toResolvedTopicOutput

  {
    resources: [topic->Util_SNS_FIFO.toResource(~tags=tags->Pulumi.Output.fromInput)],
    publishJson: resolvedTopicOutput->Pulumi.Output.apply(resolvedTopic =>
      EventTopicPublisher_SNS_Runtime.publishFifo(resolvedTopic, ...)
    ),
    publishJsonStream: resolvedTopicOutput->Pulumi.Output.apply(resolvedTopic => {
      let publishJson = EventTopicPublisher_SNS_Runtime.publishFifo(resolvedTopic, ...)
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
