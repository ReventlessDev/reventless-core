// AWS StateChangeSlice builder.

module Make = (
  Spec: Reventless.StateChangeSlice.Spec,
  Behavior: Reventless.StateChangeSlice.Behavior with module Spec := Spec,
): (ReventlessCore.StateChangeSlice.T with module Spec = Spec) => {
  PluginRuntime_Builder.registerStateChangeSliceSpec(
    Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
  )
  module Inner = ReventlessCore.StateChangeSlice_Builder.Make(Spec, Behavior)
  module Spec = Spec
  module Behavior = Behavior
  let isAsync = Inner.isAsync
  type component = Inner.component
  let make = Inner.make
}
