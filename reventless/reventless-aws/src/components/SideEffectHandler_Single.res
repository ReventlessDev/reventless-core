module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

module EventCollectorRuntimeBuilder = SideEffectHandlerRuntime_Builder_Single

module type Config = {
  let sideEffectModulePaths: array<string>
}

module Make = (Config: Config): ReventlessCore.SideEffectHandler.T => {
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

    EventCollectorRuntimeBuilder.registerSideEffectHandler(
      ~sideEffectHandlerName=name,
      ~sideEffectModulePaths=Config.sideEffectModulePaths,
    )

    component
  }
}
