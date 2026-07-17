module CommandTopicChannel = CommandTopicChannel.SQS_Sync
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module ExtensionPointRuntimeBuilder = ExtensionPointRuntime_Builder_PerExtensionPoint

// Per-extension-point Lambda floor for AWS; a plugin.json `runtime` override
// raises it via `RuntimeHints.resolveMemory`/`resolveTimeout`.
module Defaults: ReventlessInfra.RuntimeDefaults.T = {
  let memorySize = 1024
  let timeout = 30
}

module Make = (
  Spec: ReventlessInfra.ExtensionPointMapping.Spec,
  Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec,
): ReventlessInfra.ExtensionPoint.T =>
  ReventlessCore.ExtensionPoint_Builder.Make(
    Spec,
    Mappings,
    RuntimeEnvironment,
    CommandTopicChannel,
    EventTopicPublisher.SNS,
    ExtensionPointRuntimeBuilder,
    Defaults,
  )
