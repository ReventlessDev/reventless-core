module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

// The AWS builder, not `ReventlessCore.EventCollectorRuntime_Builder_PerEventCollector.Make`.
// Core's builds its Lambda through `RuntimeEnvironment.make`, which is
// `CallbackFunction` — a serialized closure — and the handler it is given closes
// over Effect, which Pulumi's closure walker cannot serialize. That made a
// side-effect handler's Lambda silently absent, and its sibling
// `SideEffectHandler_Single` was already reaching for the compiled AWS builder;
// only this arm was left behind. AWS's is a plain module rather than a functor
// because it is already bound to DynamoDbStream and the Lambda environment.
module EventCollectorRuntimeBuilder = EventCollectorRuntime_Builder_PerEventCollector

include ReventlessCore.SideEffectHandler_Builder.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
  ReventlessCore.EventCollector_Builder.Make(RuntimeEnvironment, EventCollectorChannel),
  EventCollectorRuntimeBuilder,
)
