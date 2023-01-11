open PulumiAws;

let make: Reventless.EventTopic.Adapter.publisherMaker =
  (~name, ~storageResources as _, ~opts) => {
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
      resources: [|topic->Util_SNS_FIFO.toResource|],
      publish: topic->EventTopicPublisher_SNS_Runtime.publishFifo,
    };
  };
