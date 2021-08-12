let commandTopicConnectorResource = aggregateName =>
  aggregateName
  ->ComponentType.name(ComponentType.Aggregate)
  ->Util_CommandTopic.getConnectorResource;
let eventLogStorageResource = aggregateName =>
  aggregateName
  ->ComponentType.name(ComponentType.Aggregate)
  ->Util_EventLog.getStorageResource;
let eventTopicPublisherResource = aggregateName =>
  aggregateName
  ->ComponentType.name(ComponentType.Aggregate)
  ->Util_EventTopic.getPublisherResource;

let eventTopics = aggregateNames =>
  aggregateNames
  ->Belt.Array.map(aggregateName =>
      (aggregateName, aggregateName->eventTopicPublisherResource)
    )
  ->Belt.Array.map(((aggregateName, topic)) =>
      (topic##service, (aggregateName, topic))
    );
