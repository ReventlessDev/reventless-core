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

let allEventTopics = allAggregates =>
  Js.Dict.map(
    (. aggregate) => aggregate##eventLog##eventTopic,
    allAggregates,
  );

let findEventTopics = (allAggregates, aggregateNames) =>
  aggregateNames
  ->Belt.Set.String.toArray
  ->Belt.Array.keepMap(aggregateName =>
      allAggregates
      ->Js.Dict.get(aggregateName)
      ->Belt.Option.map(aggregateOutput =>
          (aggregateName, aggregateOutput##eventLog##eventTopic)
        )
    )
  ->Js.Dict.fromArray;
