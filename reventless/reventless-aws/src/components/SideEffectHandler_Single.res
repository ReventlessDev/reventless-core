module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

module EventCollectorRuntimeBuilder = SideEffectHandlerRuntime_Builder_Single

module Make = (): ReventlessCore.SideEffectHandler.T => {
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

    // Derive npm specifiers from moduleUrl on each SideEffect module
    let sideEffectModulePaths = sideEffects->Array.map(
      (module(SE: Reventless.SideEffect.T)) =>
        Util_Bundle.getModuleSpecifier(SE.moduleUrl),
    )

    EventCollectorRuntimeBuilder.registerSideEffectHandler(
      ~sideEffectHandlerName=name,
      ~sideEffectModulePaths,
    )

    component
  }
}
