// In-memory ExtensionPoint builder.

module Make = (Bus: InMemory_Bus.T) => {
  module RuntimeEnvironment = RuntimeEnvironment_InMemory
  module CommandTopicChannel = CommandTopicChannel_InMemory.Make(Bus)
  module EventTopicPublisher = EventTopicPublisher_InMemory.Make(Bus)
  module ExtensionPointRuntimeBuilder =
    ReventlessCore.ExtensionPointRuntime_Builder_PerExtensionPoint.Make(
      RuntimeEnvironment,
      CommandTopicChannel,
    )

  module Make = (
    Spec: ReventlessInfra.ExtensionPointMapping.Spec,
    Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec,
  ): ReventlessInfra.ExtensionPoint.T =>
    ReventlessCore.ExtensionPoint_Builder.Make(
      Spec,
      Mappings,
      RuntimeEnvironment,
      CommandTopicChannel,
      EventTopicPublisher,
      ExtensionPointRuntimeBuilder,
    )
}
