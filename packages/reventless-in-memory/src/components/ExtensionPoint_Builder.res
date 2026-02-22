// In-memory ExtensionPoint builder.

module Make = (Bus: InMemory_Bus.T) => {
  module RuntimeEnvironment = RuntimeEnvironment_InMemory
  module CommandTopicChannel = CommandTopicChannel_InMemory.Make(Bus)
  module EventTopicPublisher = EventTopicPublisher_InMemory.Make(Bus)
  module ExtensionPointRuntimeBuilder =
    Reventless.ExtensionPointRuntime_Builder_PerExtensionPoint.Make(
      RuntimeEnvironment,
      CommandTopicChannel,
    )

  module Make = (
    Spec: ReventlessSpec.ExtensionPointMapping.Spec,
    Mappings: ReventlessSpec.ExtensionPoint.Mappings with module Spec := Spec,
  ): ReventlessSpec.ExtensionPoint.T =>
    Reventless.ExtensionPoint_Builder.Make(
      Spec,
      Mappings,
      RuntimeEnvironment,
      CommandTopicChannel,
      EventTopicPublisher,
      ExtensionPointRuntimeBuilder,
    )
}
