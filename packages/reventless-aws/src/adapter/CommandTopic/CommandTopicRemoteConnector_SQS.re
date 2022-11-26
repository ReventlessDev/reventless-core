let make: Reventless.CommandTopic.Adapter.remoteConnectorMaker =
  commandTopicOutputs => {
    {
      remotePublish:
        commandTopicOutputs##resources
        ->Util.SQS.findResource
        ->Util.SQS.fromResource
        ->CommandTopicConnector_SQS_Runtime.publish(Util_SQS.service),
    };
  };
