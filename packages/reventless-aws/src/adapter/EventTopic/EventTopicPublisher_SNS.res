open PulumiAws

let make: Reventless.EventTopic.Adapter.publisherMaker = (~name, ~storageResources as _, ~opts) => {
  let topic = SNS.Topic.make(
    ~name,
    ~args={SNS.Topic.tags: AWS.tags(~name, Reventless.EventTopic.componentType)},
    ~opts,
  )

  {
    resources: [topic->Util_SNS.toResource],
    publishJson: topic
    ->Util_SNS.toRuntimeTopicOutput
    ->Pulumi.Output.apply(runtimeTopic =>
      EventTopicPublisher_SNS_Runtime.publish(runtimeTopic, ...)
    ),
  }
}
