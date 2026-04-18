open PulumiAws

/** EventTopic names backed by SNS (not DynamoDB stream).
    Read by subscriptionInfraHook (Phase 5) to skip non-SNS entries. */
let snsRegistry: Set.t<string> = Set.make()

let make: ReventlessCore.EventTopic_Adapter.publisherMaker = (~name, ~storageResources as _, ~opts) => {
  snsRegistry->Set.add(name)
  let tags = AWS.Tags.make(~name, ReventlessCore.EventTopic.componentType)
  let topic = SNS.Topic.make(
    ~name,
    ~args={SNS.Topic.tags: tags},
    ~opts,
  )

  let resolvedTopicOutput = topic->Util_SNS.toResolvedTopicOutput

  {
    resources: [topic->Util_SNS.toResource(~tags=tags->Pulumi.Output.fromInput)],
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
