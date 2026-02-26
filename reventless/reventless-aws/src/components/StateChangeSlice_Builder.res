module Make = (Spec: Reventless.StateChangeSlice.Spec): (
  ReventlessCore.StateChangeSlice.T
    with type dcbEvent = Spec.DcbEventLogSpec.event
    and module Spec = Spec
) => ReventlessCore.StateChangeSlice_Builder.Make(Spec)
