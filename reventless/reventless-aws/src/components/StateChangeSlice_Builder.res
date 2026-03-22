module Make = (Spec: Reventless.StateChangeSlice.Spec): (
  ReventlessCore.StateChangeSlice.T
    with type dcbEvent = Spec.DcbEventLogSpec.event
    and module Spec = Spec
) => {
  PluginRuntime_Builder.registerStateChangeSliceSpec(
    Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
  )
  include ReventlessCore.StateChangeSlice_Builder.Make(Spec)
}
