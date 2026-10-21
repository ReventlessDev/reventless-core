// AWS StateChangeSlice builder.

module Make = (
  Spec: Reventless.StateChangeSlice.Spec,
  Decision: Reventless.StateChangeSlice.Decision with module Spec := Spec,
): (ReventlessCore.StateChangeSlice.T with module Spec = Spec) => {
  PluginRuntime_Builder.registerStateChangeSliceSpec(
    ~specPath=Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
    ~decisionPath=Util_Bundle.getModuleSpecifier(Decision.moduleUrl),
  )
  module Inner = ReventlessCore.StateChangeSlice_Builder.Make(Spec, Decision)
  module Spec = Spec
  module Decision = Decision
  let isAsync = Inner.isAsync
  type component = Inner.component
  let make = Inner.make
}
