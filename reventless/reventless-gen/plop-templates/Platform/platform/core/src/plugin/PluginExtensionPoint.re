module PluginExtensionPoint =
  Reventless.PluginExtensionPoint.Make(
    ReventlessAws.CommandTopicConnector.SQS,
    ReventlessAws.EventTopicPublisher.SNS,
  );

let make = PluginExtensionPoint.make;
