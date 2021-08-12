let setCommandTopicConnectorResource = (resource, extensionPointName) =>
  resource->Util_CommandTopic.setConnectorResource(
    extensionPointName->ComponentType.name(ExtensionPoint.componentType),
  );
let setEventTopicPublisherResource = (resource, extensionPointName) =>
  resource->Util_EventTopic.setPublisherResource(
    extensionPointName->ComponentType.name(ExtensionPoint.componentType),
  );

let commandTopicConnectorResource = extensionPointName =>
  extensionPointName
  ->ComponentType.name(ExtensionPoint.componentType)
  ->Util_CommandTopic.getConnectorResource;
let eventTopicPublisherResource = extensionPointName =>
  extensionPointName
  ->ComponentType.name(ExtensionPoint.componentType)
  ->Util_EventTopic.getPublisherResource;

let eventTopics = extensionPointNames =>
  extensionPointNames
  ->Belt.Array.map(extensionPointName =>
      (extensionPointName, extensionPointName->eventTopicPublisherResource)
    )
  ->Belt.Array.map(((extensionPointName, topic)) =>
      (topic##service, (extensionPointName, topic))
    );
