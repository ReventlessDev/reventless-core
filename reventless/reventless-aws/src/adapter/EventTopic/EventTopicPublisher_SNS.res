open PulumiAws

let make: ReventlessCore.EventTopic_Adapter.publisherMaker = (~name, ~storageResources as _, ~opts) => {
  let topic = SNS.Topic.make(
    ~name,
    ~args={SNS.Topic.tags: AWS.Tags.make(~name, ReventlessCore.EventTopic.componentType)},
    ~opts,
  )

  let resolvedTopicOutput = topic->Util_SNS.toResolvedTopicOutput

  {
    resources: [topic->Util_SNS.toResource],
    publishJson: resolvedTopicOutput->Pulumi.Output.apply(resolvedTopic =>
      EventTopicPublisher_SNS_Runtime.publish(resolvedTopic, ...)
    ),
    publishJsonStream: resolvedTopicOutput->Pulumi.Output.apply(resolvedTopic => {
      let publishJson = EventTopicPublisher_SNS_Runtime.publish(resolvedTopic, ...)
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
