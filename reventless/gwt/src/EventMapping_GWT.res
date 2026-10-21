open ReventlessCore

// Stage 5 — `EventMapping_GWT` is now a thin alias over `Mapping_GWT`
// specialised for the Aggregate → Aggregate case. New tests should use
// `Mapping_GWT.Make` directly with `Mapping_GWT.FromDecision` adapters; this
// wrapper is retained for migration backward-compat with consumers that were
// already calling `EventMapping_GWT.Make(Source, SourceDecision, Target,
// TargetDecision, EventMapping)` before Stage 5 landed.

module Make = (
  Source: Reventless.Aggregate.Spec,
  SourceDecision: Decision.T with module Spec = Source,
  Target: Reventless.Aggregate.Spec,
  TargetDecision: Decision.T with module Spec = Target,
  EventMapping: Reventless.EventMapping.T with module Source = Source and module Target = Target,
) => {
  module AdaptedSource = Mapping_GWT.FromDecision(Source, SourceDecision)
  module AdaptedTarget = Mapping_GWT.FromDecision(Target, TargetDecision)

  module BoundMapping = {
    module Source = AdaptedSource
    module Target = AdaptedTarget
    let map = EventMapping.map
  }

  include Mapping_GWT.Make(BoundMapping)
}
