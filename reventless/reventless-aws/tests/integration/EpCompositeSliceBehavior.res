// Behavior pair for `EpCompositeSlice`. Append-on-empty / reject-on-seen, per
// composite entity: the decision read is scoped to one `{environment,
// resourceName}` composite, so a fresh resource sees empty state and appends,
// while a duplicate of the same composite key sees `true` and is rejected.

type state = bool

let initialState = false

let evolve = (_state, _event: EpCompositeSlice.consumedEvent) => true

let decide = (state, command: EpCompositeSlice.command): result<
  array<EpCompositeSlice.event>,
  EpCompositeSlice.error,
> =>
  switch (state, command) {
  | (true, _) => Error(AlreadyAdded)
  | (false, AddResource({environment, resourceName})) =>
    Ok([ResourceAdded({environment, resourceName})])
  }

let moduleUrl = "ep-test://EpCompositeSliceBehavior"
