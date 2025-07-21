open PulumiAws

let make: Reventless.EventTopic_Adapter.publisherMaker = (~name, ~storageResources as _, ~opts) => {
  let topic = SNS.Topic.make(
    ~name,
    ~args={
      SNS.Topic.fifoTopic: true->Pulumi.Input.make,
      contentBasedDeduplication: true->Pulumi.Input.make,
      tags: AWS.Tags.make(~name, Reventless.EventTopic.componentType),
    },
    ~opts,
  )

  {
    resources: [topic->Util_SNS_FIFO.toResource],
    publishJson: topic
    ->Util_SNS.toRuntimeTopicOutput
    ->Pulumi.Output.apply(runtimeTopic =>
      EventTopicPublisher_SNS_Runtime.publishFifo(runtimeTopic, ...)
    ),
  }
}
