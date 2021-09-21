module Deploytime = {
  let setEventTopicPublisherResource = (resource, extensionPointName) =>
    Util_EventTopic.Deploytime.setPublisherResource(
      resource,
      extensionPointName->ComponentType.name(ComponentType.ExtensionPoint),
    );

  let setCommandTopicConnectorResource = (resource, extensionPointName) =>
    Util_CommandTopic.Deploytime.setConnectorResource(
      resource,
      extensionPointName->ComponentType.name(ComponentType.ExtensionPoint),
    );

  let eventTopicPublisherResource = extensionPointName =>
    Util_EventTopic.Deploytime.getPublisherResource(
      extensionPointName->ComponentType.name(ComponentType.ExtensionPoint),
    );

  let eventTopics = extensionPointNames =>
    extensionPointNames
    ->Belt.Array.map(extensionPointName =>
        (extensionPointName, eventTopicPublisherResource(extensionPointName))
      )
    ->Belt.Array.map(((extensionPointName, topic)) =>
        (topic##service, (extensionPointName, topic))
      );
};

module Runtime = {
  let commandTopicConnectorResource = extensionPointName =>
    Util_CommandTopic.Runtime.getConnectorResource(
      extensionPointName->ComponentType.name(ComponentType.ExtensionPoint),
    );
};
