let commandTopicConnectorResource = (resources, aggregateName) =>
  resources->Util_CommandTopic.getConnectorResource(
    aggregateName->ComponentType.name(ComponentType.Aggregate),
  );
let eventLogStorageResource = (resources, aggregateName) =>
  resources->Util_EventLog.getStorageResource(
    aggregateName->ComponentType.name(ComponentType.Aggregate),
  );
let eventTopicPublisherResource = (resources, aggregateName) =>
  resources->Util_EventTopic.getPublisherResource(
    aggregateName->ComponentType.name(ComponentType.Aggregate),
  );

let eventTopics = (resources, aggregateNames) =>
  aggregateNames
  ->Belt.Array.map(aggregateName =>
      (aggregateName, resources->eventTopicPublisherResource(aggregateName))
    )
  ->Belt.Array.map(((aggregateName, topic)) =>
      (topic##service, (aggregateName, topic))
    );
