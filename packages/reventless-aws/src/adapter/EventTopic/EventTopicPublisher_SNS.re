open PulumiAws;

let make: Reventless.EventTopic.publisherMaker =
  (~name, ~opts) => {
    let topic =
      SNS.Topic.make(
        ~name,
        ~args=
          SNS.Topic.Args.make(
            ~fifoTopic=true->Pulumi.Input.wrap,
            ~contentBasedDeduplication=true->Pulumi.Input.wrap,
            (),
          ),
        ~opts,
        (),
      );

    Reventless.EventTopic.{
      resource: topic->Util_SNS.toResource,
      publish: topic->EventTopicPublisher_SNS_Runtime.publish,
    };
  };
