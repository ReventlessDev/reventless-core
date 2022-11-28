let make: Reventless.CommandTopic.Adapter.remoteConnectorMaker =
  commandTopicOutputs => {
    {
      remotePublish:
        commandTopicOutputs##resources
        ->Belt.Array.map(Reventless.AdapterDeploytime.unsafeUnwrapResource)
        ->Util.SQS.findUnwrappedResource
        ->Reventless.Adapter.unwrappedToResource
        ->Util.SQS.fromResource
        ->CommandTopicConnector_SQS_Runtime.publish(Util_SQS.service),
    };
  };
