// StateChangeSlice builder — no platform-specific adapters needed.

module Make = (Spec: ReventlessSpec.StateChangeSlice.Spec): (
  Reventless.StateChangeSlice.T
    with type dcbEvent = Spec.DcbEventLogSpec.event
    and module Spec = Spec
) => Reventless.StateChangeSlice_Builder.Make(Spec)
