open PulumiAws;

let make: Reventless.EventTopic.Adapter.publisherMaker =
  (~name, ~opts, ~resources as _) => {
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

    {
      resource: topic->Util_SNS_FIFO.toResource,
      publish: topic->EventTopicPublisher_SNS_FIFO_Runtime.publish,
    };
  };
