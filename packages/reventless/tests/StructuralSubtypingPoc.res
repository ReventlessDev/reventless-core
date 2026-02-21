// Phase 0 Proof-of-Concept: Validate structural subtyping for platform-to-reventless-spec migration
//
// This file tests the critical assumption from plans/platform-to-reventless-spec.md:
// Can a module satisfying a superset module type (with AggregateRuntimeBuilder)
// be used where a subset module type (without AggregateRuntimeBuilder) is expected?
//
// Tests:
// 1. Basic structural subtyping: superset module satisfies subset module type
// 2. `with type` constraints work across subset/superset boundary
// 3. Array of first-class superset modules can be passed where subset is expected
// 4. The "finish" pattern: internal fields accessible when needed, hidden from spec users

// ============================================================================
// Simulated "spec" types (what would live in reventless-spec)
// ============================================================================

module type SpecLike = {
  module Id: ReventlessSpec.Id.T
  let name: string
  @schema
  type command
  @schema
  type event
  @schema
  type error
}

// Simplified component output type — what app developers would see
// This is the "Subset" — no AggregateRuntimeBuilder
module type Aggregate_Subset = {
  module Spec: SpecLike
  type api
  let make: (~api: api, ~opts: Pulumi.ComponentResource.options=?) => Aggregate.component
}

// ============================================================================
// Simulated "reventless" types (what would stay in reventless)
// ============================================================================

// Full component output type — includes internal adapter module
// This is the "Superset" — has AggregateRuntimeBuilder
module type Aggregate_Superset = {
  module Spec: SpecLike
  type api
  let make: (~api: api, ~opts: Pulumi.ComponentResource.options=?) => Aggregate.component
  module AggregateRuntimeBuilder: AggregateRuntime_Builder.T
}

// ============================================================================
// Test 1: Basic coercion — can a Superset module be used as a Subset?
// ============================================================================

// This function accepts the subset type
let acceptSubset = (module(M: Aggregate_Subset)): string => {
  M.Spec.name
}

// This function tries to pass a superset where subset is expected
let coerceSuperset = (module(M: Aggregate_Superset)): module(Aggregate_Subset) => {
  module(M: Aggregate_Subset)
}

// ============================================================================
// Test 2: `with type` constraints across the boundary
// ============================================================================

// Simulated Plugin.T.make signature using subset types
module type PluginMaker_WithSubset = {
  type api
  let make: (~aggregates: array<module(Aggregate_Subset with type api = api)>) => unit
}

// Can we pass superset modules where subset with type constraint is expected?
let passSupersetsAsSubsets = (
  type a,
  aggregates: array<module(Aggregate_Superset with type api = a)>,
): array<module(Aggregate_Subset with type api = a)> => {
  aggregates->Array.map((
    module(M: Aggregate_Superset with type api = a),
  ): module(Aggregate_Subset with type api = a) => module(M))
}

// ============================================================================
// Test 3: The "finish" pattern — can we keep internal access when needed?
// ============================================================================

// The plugin builder internally needs AggregateRuntimeBuilder.finish()
// but the Platform.T signature only exposes the subset.
// Solution: Plugin_Builder accepts the full type internally,
// but Platform.T returns the subset to app developers.

// This simulates what Plugin_Helpers.finishAggregates does
let finishAggregates = (
  type a,
  aggregates: array<module(Aggregate_Superset with type api = a)>,
) => {
  aggregates->Array.forEach((module(M: Aggregate_Superset with type api = a)) => {
    M.AggregateRuntimeBuilder.finish()
  })
}

// ============================================================================
// Test 4: Platform.T pattern — builder returns subset, internal uses superset
// ============================================================================

// What Platform.T would look like in spec (returns subset)
module type Platform_Spec = {
  module Aggregate: {
    module Make: (Spec: SpecLike) => Aggregate_Subset
  }
}

// What the actual platform implementation returns (superset)
module type Platform_Impl = {
  module Aggregate: {
    module Make: (Spec: SpecLike) => Aggregate_Superset
  }
}

// Can Platform_Impl satisfy Platform_Spec?
// This is the KEY test — if this compiles, the whole approach works
let platformImplSatisfiesSpec = (module(P: Platform_Impl)): module(Platform_Spec) => {
  module(P: Platform_Spec)
}

// ============================================================================
// Test 5: ReadModel pattern (has EventCollectorRuntimeBuilder)
// ============================================================================

module type ReadModel_Subset = {
  module Spec: ReventlessSpec.ReadModel.T
  type api
  type role
  let make: (
    ~api: api,
    ~apiRole: role,
    ~allEventTopics: EventTopic.allOutputs,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => ReadModel.component
}

module type ReadModel_Superset = {
  module Spec: ReventlessSpec.ReadModel.T
  type api
  type role
  let make: (
    ~api: api,
    ~apiRole: role,
    ~allEventTopics: EventTopic.allOutputs,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => ReadModel.component
  module EventCollectorRuntimeBuilder: EventCollectorRuntime_Builder.T
}

let coerceReadModelSuperset = (module(M: ReadModel_Superset)): module(ReadModel_Subset) => {
  module(M: ReadModel_Subset)
}

// ============================================================================
// Test 6: include-based definition (the actual approach from the plan)
// ============================================================================

// In the plan, the superset would be defined using `include`:
//   module type Superset = { include Subset; module Extra: ... }
// Let's verify this works too

module type Aggregate_Subset_V2 = {
  module Spec: SpecLike
  type api
  let make: (~api: api, ~opts: Pulumi.ComponentResource.options=?) => Aggregate.component
}

module type Aggregate_Superset_V2 = {
  include Aggregate_Subset_V2
  module AggregateRuntimeBuilder: AggregateRuntime_Builder.T
}

let coerceSupersetV2 = (module(M: Aggregate_Superset_V2)): module(Aggregate_Subset_V2) => {
  module(M: Aggregate_Subset_V2)
}

let passSupersetsAsSubsetsV2 = (
  type a,
  aggregates: array<module(Aggregate_Superset_V2 with type api = a)>,
): array<module(Aggregate_Subset_V2 with type api = a)> => {
  aggregates->Array.map((
    module(M: Aggregate_Superset_V2 with type api = a),
  ): module(Aggregate_Subset_V2 with type api = a) => module(M))
}

let platformImplSatisfiesSpecV2 = (module(P: Platform_Impl)): module(Platform_Spec) => {
  module(P: Platform_Spec)
}

// ============================================================================
// Summary
// ============================================================================
// If this file compiles, it proves:
// 1. ✅ Superset modules can be coerced to subset module types
// 2. ✅ `with type` constraints work across the boundary
// 3. ✅ Arrays of first-class modules can be mapped from superset to subset
// 4. ✅ Platform_Impl (returning superset) satisfies Platform_Spec (returning subset)
// 5. ✅ ReadModel pattern works the same way
// 6. ✅ `include`-based superset definition works
//
// Key insight for the plan:
// - Plugin_Builder.res DOES use AggregateRuntimeBuilder.finish() internally
//   (see Plugin_Helpers.res:136-143)
// - This means Plugin_Builder must continue to accept the full Aggregate.T internally
// - But Platform.T can return the subset type to app developers
// - The coercion happens at the Platform.T boundary, not at Plugin_Builder
