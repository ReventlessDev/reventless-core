module CommandTopicChannel = CommandTopicChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module ExtensionPointRuntimeBuilder = ExtensionPointRuntime_Builder_PerExtensionPoint

module type Config = {
  let publishToAggregatesQueueUrls: dict<Pulumi.Output.t<string>>
}

module Make = (
  Spec: ReventlessInfra.ExtensionPointMapping.Spec,
  Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec,
  Config: Config,
): ReventlessInfra.ExtensionPoint.T => {
  module Inner = ReventlessCore.ExtensionPoint_Builder.Make(
    Spec,
    Mappings,
    RuntimeEnvironment,
    CommandTopicChannel,
    EventTopicPublisher.SNS,
    ExtensionPointRuntimeBuilder,
  )

  ExtensionPointRuntimeBuilder.registerExtensionPoint(
    ~name=Spec.name,
    ~specModulePath=Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
    ~mappingsModulePath=Util_Bundle.getModuleSpecifier(Mappings.moduleUrl),
    ~publishToAggregatesQueueUrls=Config.publishToAggregatesQueueUrls,
  )

  type operations = Inner.operations
  type component = Inner.component

  let make = Inner.make
  let outputs = Inner.outputs
  let operations = Inner.operations
}
