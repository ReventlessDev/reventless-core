module type T = {
  module Spec: ReventlessSpec.ExtensionPointMapping.Spec;
  module type Mapping =
    ExtensionPointMapping.T with module ExtensionPoint := Spec;
  let make: ExtensionPoint.maker;
};

module Make =
       (
         CommandTopicAdapter: CommandTopic.Connector,
         EventTopicAdapter: EventTopic.Publisher,
       )
       : (T with module Spec := ReventlessSpec.PluginExtensionPointSpec) => {
  include ExtensionPoint.Make(
            ReventlessSpec.PluginExtensionPointSpec,
            CommandTopicAdapter,
            EventTopicAdapter,
          );

  let make = make([|(module PluginExtensionPoint_Plugin.Mapping)|]);
};
