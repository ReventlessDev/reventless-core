module type T = {
  module Spec: ExtensionPointMapping.Spec;
  module type Mapping =
    ExtensionPointMapping.T with module ExtensionPoint := Spec;
  let make: ExtensionPoint.maker;
};

module Make =
       (
         CommandTopicAdapter: CommandTopic.Connector,
         EventTopicAdapter: EventTopic.Publisher,
       )
       : (T with module Spec := PluginExtensionPointSpec) => {
  include ExtensionPoint.Make(
            PluginExtensionPointSpec,
            CommandTopicAdapter,
            EventTopicAdapter,
          );

  let make = make([|(module PluginExtensionPoint_PluginMapping.Mapping)|]);
};
