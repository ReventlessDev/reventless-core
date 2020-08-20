module type T = {
  module Spec: ExtensionPointMapping.Spec;
  module type Mapping =
    ExtensionPointMapping.T with module ExtensionPoint := Spec;
  let make: ExtensionPoint.maker;
};

module Make =
       (
         EventCollectorAdapter: EventCollector.Connector,
         CommandTopicAdapter: CommandTopic.Connector,
         EventTopicAdapter: EventTopic.Publisher,
       )
       : (T with module Spec := PluginExtensionPointSpec) => {
  include ExtensionPoint.Make(
            PluginExtensionPointSpec,
            EventCollectorAdapter,
            CommandTopicAdapter,
            EventTopicAdapter,
          );

  let make = make([|(module PluginExtensionPoint_PluginMapping.Mapping)|]);
};

//module PluginMapping = PluginExtensionPoint_PluginMapping;
