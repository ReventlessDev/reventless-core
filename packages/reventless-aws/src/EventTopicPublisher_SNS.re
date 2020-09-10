let make: Reventless.EventTopic.publisherMaker =
  (~name, ~opts) => {
    let topicName = name;
    let topic = PulumiAws.SNS.Topic.make(~name=topicName, ~opts, ());

    Reventless.EventTopic.{
      resource: topic->Util_SNS.toResource,
      publish: topic->EventTopicPublisher_SNS_Runtime.publish,
    };
  };
