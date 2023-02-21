open PulumiAws;

let make: Reventless.EventTopic.Adapter.publisherMaker =
  (~name, ~storageResources as _, ~opts) => {
    let topic =
      SNS.Topic.make(
        ~name,
        ~args=
          SNS.Topic.Args.make(
            ~fifoTopic=true->Pulumi.Input.make,
            ~contentBasedDeduplication=true->Pulumi.Input.make,
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
