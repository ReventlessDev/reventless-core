let setCommandTopicConnectorResource =
    (resources, resource, extensionPointName) =>
  resources->Util_CommandTopic.setConnectorResource(
    resource,
    extensionPointName->ComponentType.name(ComponentType.ExtensionPoint),
  );
let setEventTopicPublisherResource = (resources, resource, extensionPointName) =>
  resources->Util_EventTopic.setPublisherResource(
    resource,
    extensionPointName->ComponentType.name(ComponentType.ExtensionPoint),
  );

let commandTopicConnectorResource = (resources, extensionPointName) =>
  resources->Util_CommandTopic.getConnectorResource(
    extensionPointName->ComponentType.name(ComponentType.ExtensionPoint),
  );
let eventTopicPublisherResource = (resources, extensionPointName) =>
  resources->Util_EventTopic.getPublisherResource(
    extensionPointName->ComponentType.name(ComponentType.ExtensionPoint),
  );

let eventTopics = (resources, extensionPointNames) =>
  extensionPointNames
  ->Belt.Array.map(extensionPointName =>
      (
        extensionPointName,
        resources->eventTopicPublisherResource(extensionPointName),
      )
    )
  ->Belt.Array.map(((extensionPointName, topic)) =>
      (topic##service, (extensionPointName, topic))
    );
