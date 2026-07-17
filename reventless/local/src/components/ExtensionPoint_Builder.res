// In-memory ExtensionPoint builder.

module Make = (Bus: LocalBus.T) => {
  module RuntimeEnvironment = LocalRuntimeEnvironment
  module CommandTopicChannel = LocalCommandTopicChannel.Make(Bus)
  module EventTopicPublisher = LocalEventTopicPublisher.Make(Bus)
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
