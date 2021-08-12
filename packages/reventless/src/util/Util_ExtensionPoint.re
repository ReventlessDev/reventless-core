let setCommandTopicConnectorResource = (resource, extensionPointName) =>
  resource->CommandTopic.Adapter.setConnectorResource(
    extensionPointName->ComponentType.name(ExtensionPoint.componentType),
  );
let setEventTopicPublisherResource = (resource, extensionPointName) =>
  resource->EventTopic.Adapter.setPublisherResource(
    extensionPointName->ComponentType.name(ExtensionPoint.componentType),
  );

let commandTopicConnectorResource = extensionPointName =>
  extensionPointName
  ->ComponentType.name(ExtensionPoint.componentType)
  ->CommandTopic.Adapter.getConnectorResource;
let eventTopicPublisherResource = extensionPointName =>
  extensionPointName
  ->ComponentType.name(ExtensionPoint.componentType)
  ->EventTopic.Adapter.getPublisherResource;

let eventTopics = extensionPointNames =>
  extensionPointNames
  ->Belt.Array.map(extensionPointName =>
      (extensionPointName, extensionPointName->eventTopicPublisherResource)
    )
  ->Belt.Array.map(((extensionPointName, topic)) =>
      (topic##service, (extensionPointName, topic))
    );
