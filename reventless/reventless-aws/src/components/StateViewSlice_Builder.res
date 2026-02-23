module Make = (Spec: ReventlessSpec.StateViewSlice.Spec): (
  Reventless.StateViewSlice.T with type dcbEvent = Spec.DcbEventLogSpec.event and module Spec = Spec
) => Reventless.StateViewSlice_Builder.Make(Spec)
