open PulumiAws

let make: Reventless.EventTopic.Adapter.publisherMaker = (~name, ~storageResources as _, ~opts) => {
  let topic = SNS.Topic.make(
    ~name,
    ~args={SNS.Topic.tags: AWS.tags(~name, Reventless.EventTopic.componentType)},
  )

  {
    resources: [topic->Util_SNS.toResource],
    publish: topic->EventTopicPublisher_SNS_Runtime.publish,
  }
}
