module Deploytime = {
  let eventTopicPublisherResource = aggregateName =>
    Util_EventTopic.Deploytime.getPublisherResource(
      aggregateName->ComponentType.name(ComponentType.Aggregate),
    );

  let eventTopics = aggregateNames =>
    aggregateNames
    ->Belt.Array.map(aggregateName =>
        (aggregateName, eventTopicPublisherResource(aggregateName))
      )
    ->Belt.Array.map(((aggregateName, topic)) =>
        (topic##service, (aggregateName, topic))
      );

  let eventLogStorageResource = aggregateName =>
    Util_EventLog.Deploytime.getStorageResource(
      aggregateName->ComponentType.name(ComponentType.Aggregate),
    );
};

module Runtime = {
  let commandTopicConnectorResource = aggregateName =>
    Util_CommandTopic.Runtime.getConnectorResource(
      aggregateName->ComponentType.name(ComponentType.Aggregate),
    );
};
