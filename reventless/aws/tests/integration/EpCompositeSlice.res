// Composite-partition slice fixture for `DcbCommandTopicEntryPoint_IntegrationTest`.
//
// Reproduces the deploy-sync workload shape from
// docs/plans/done/dcb-composite-fence-residual-burst-contention.md: a
// `@compositePartitionTag` over a low-cardinality prefix (`environment`) plus a
// high-cardinality tail (`resourceName`). Distinct resources sharing the same
// `environment` must NOT contend — but only if the entry point threads
// `partitionTag = Composite(...)` into the DynamoDB `append`, activating the
// single-composite-fence collapse. Without that thread the slice writes one
// fence per member and the shared `environment` member goes hot.
//
// It ALSO guards the composite read-back invariant from
// docs/plans/done/dcb-composite-query-clause-fence-contention.md: `TouchResource`
// requires the slice to READ its own prior `ResourceAdded` (state must be
// `Added`), which only works if the stored `tag_composite` key matches the read
// key — i.e. the framework `originatorSlice` provenance tag is excluded from the
// composite key. With that bug present the read misses, state stays `Absent`, and
// `TouchResource` is rejected `NotFound`.
//
// Explicit `@s.matches(Reventless.DcbTag.compositePartitionMember(...))` form
// (not the `@compositePartitionTag` PPX shorthand) because reventless-ppx is not
// wired into reventless-aws's rescript.json — same reason as EpTestSlice.

@schema
type consumedEvent =
  | ResourceAdded({environment: string, resourceName: string})
  | ResourceTouched({environment: string, resourceName: string})

@schema
type command =
  | AddResource({
      environment: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=0, ~sep="/")) string,
      resourceName: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=1, ~sep="/")) string,
    })
  | TouchResource({
      environment: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=0, ~sep="/")) string,
      resourceName: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=1, ~sep="/")) string,
    })

@schema
type error =
  | AlreadyAdded
  | NotFound

@schema
type event =
  | ResourceAdded({
      environment: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=0, ~sep="/")) string,
      resourceName: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=1, ~sep="/")) string,
    })
  | ResourceTouched({
      environment: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=0, ~sep="/")) string,
      resourceName: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=1, ~sep="/")) string,
    })

let name = "EpCompositeSlice"
let moduleUrl = "ep-test://EpCompositeSlice"
let commandAuthorization = (_: command): Reventless.Authorization.permission => AllowAnonymous
type lifecycleState = unit
let commandTransition = (_: command): Reventless.Transition.t<lifecycleState> => Unrestricted
let readConsistency = Reventless.ReadConsistency.EscalateOnRetry

// `module Id = Reventless.Id.String` — patched in by `patchSpecId` at runtime.
