module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

module EventCollectorRuntimeBuilder = SideEffectHandlerRuntime_Builder_Single_Bundled

module type BundledConfig = {
  let sideEffectModulePaths: array<string>
}

module Make = (Config: BundledConfig): ReventlessCore.SideEffectHandler.T => {
  module Inner = ReventlessCore.SideEffectHandler_Builder.Make(
    RuntimeEnvironment,
    EventCollectorChannel,
    ReventlessCore.EventCollector_Builder.Make(RuntimeEnvironment, EventCollectorChannel),
    EventCollectorRuntimeBuilder,
  )

  let make = (
    ~name,
    ~sideEffects,
    ~allEventTopics,
    ~allCommandTopics,
    ~targets=?,
    ~queryEngine,
    ~scheduler,
    ~resourceNaming,
    ~memorySize=?,
    ~timeout=?,
    ~opts=?,
  ) => {
    let component = Inner.make(
      ~name,
      ~sideEffects,
      ~allEventTopics,
      ~allCommandTopics,
      ~targets?,
      ~queryEngine,
      ~scheduler,
      ~resourceNaming,
      ~memorySize?,
      ~timeout?,
      ~opts?,
    )

    EventCollectorRuntimeBuilder.registerBundledSideEffectHandler(
      ~sideEffectHandlerName=name,
      ~sideEffectModulePaths=Config.sideEffectModulePaths,
    )

    component
  }
}
