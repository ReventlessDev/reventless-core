open PulumiAws

let make: ReventlessCore.EventTopic_Adapter.publisherMaker = (~name, ~storageResources as _, ~opts) => {
  let topic = SNS.Topic.make(
    ~name,
    ~args={SNS.Topic.tags: AWS.Tags.make(~name, ReventlessCore.EventTopic.componentType)},
    ~opts,
  )

  let runtimeTopicOutput = topic->Util_SNS.toRuntimeTopicOutput

  {
    resources: [topic->Util_SNS.toResource],
    publishJson: runtimeTopicOutput->Pulumi.Output.apply(runtimeTopic =>
      EventTopicPublisher_SNS_Runtime.publish(runtimeTopic, ...)
    ),
    publishJsonStream: runtimeTopicOutput->Pulumi.Output.apply(runtimeTopic => {
      let publishJson = EventTopicPublisher_SNS_Runtime.publish(runtimeTopic, ...)
      stream =>
        stream
        ->Stream.grouped(10)
        ->Stream.runForEach(items =>
          Effect.promise(() =>
            items
            ->Array.map(({Reventless.EventTopic.service, meta, json}) =>
              publishJson(service, meta, json)
            )
            ->Promise.all
            ->Promise.thenResolve(_ => ())
          )
        )
    }),
  }
}
