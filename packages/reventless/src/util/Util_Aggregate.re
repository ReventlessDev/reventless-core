let commandTopicConnectorResource = aggregateName =>
  aggregateName
  ->ComponentType.name(Aggregate.componentType)
  ->CommandTopic.Adapter.getConnectorResource;
let eventLogStorageResource = aggregateName =>
  aggregateName
  ->ComponentType.name(Aggregate.componentType)
  ->EventLog.Adapter.getStorageResource;
let eventTopicPublisherResource = aggregateName =>
  aggregateName
  ->ComponentType.name(Aggregate.componentType)
  ->EventTopic.Adapter.getPublisherResource;

let eventTopics = aggregateNames =>
  aggregateNames
  ->Belt.Array.map(aggregateName =>
      (aggregateName, aggregateName->eventTopicPublisherResource)
    )
  ->Belt.Array.map(((aggregateName, topic)) =>
      (topic##service, (aggregateName, topic))
    );
