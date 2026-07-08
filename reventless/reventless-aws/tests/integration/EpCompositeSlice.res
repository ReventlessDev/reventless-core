// Composite-partition slice fixture for `DcbCommandTopicEntryPoint_IntegrationTest`.
//
// Reproduces the deploy-sync workload shape from
// docs/plans/dcb-composite-fence-residual-burst-contention.md: a
// `@compositePartitionTag` over a low-cardinality prefix (`environment`) plus a
// high-cardinality tail (`resourceName`). Distinct resources sharing the same
// `environment` must NOT contend — but only if the entry point threads
// `partitionTag = Composite(...)` into the DynamoDB `append`, activating the
// single-composite-fence collapse. Without that thread the slice writes one
// fence per member and the shared `environment` member goes hot.
//
// Explicit `@s.matches(Reventless.DcbTag.compositePartitionMember(...))` form
// (not the `@compositePartitionTag` PPX shorthand) because reventless-ppx is not
// wired into reventless-aws's rescript.json — same reason as EpTestSlice.

@schema
type consumedEvent = ResourceAdded({environment: string, resourceName: string})

@schema
type command = AddResource({
  environment: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=0, ~sep="/")) string,
  resourceName: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=1, ~sep="/")) string,
})

@schema
type error = AlreadyAdded

@schema
type event = ResourceAdded({
  environment: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=0, ~sep="/")) string,
  resourceName: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=1, ~sep="/")) string,
})

let name = "EpCompositeSlice"
let moduleUrl = "ep-test://EpCompositeSlice"
let commandAuthorization = (_: command): Reventless.Authorization.permission => AllowAnonymous
let readConsistency = Reventless.ReadConsistency.EscalateOnRetry

// `module Id = Reventless.Id.String` — patched in by `patchSpecId` at runtime.
