let make = (~name, ~opts) => {
  let topicName = name;
  let topic = PulumiAws.SNS.Topic.make(~name=topicName, ~opts, ());

  EventTopic.{
    resource: topic->AdapterAws_Util_SNS.toResource,
    publish: topic->AdapterAws_EventTopicPublisher_SNS_Runtime.publish,
  };
};