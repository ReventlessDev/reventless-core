let make: Reventless.CommandTopic.Adapter.remoteConnectorMaker =
  (~resource) => {
    {
      remotePublish:
        resource
        ->Util.SQS.fromResource
        ->CommandTopicConnector_SQS_Runtime.publish(Util_SQS.service),
    };
  };
