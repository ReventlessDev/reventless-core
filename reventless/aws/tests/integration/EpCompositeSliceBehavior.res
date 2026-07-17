// Behavior pair for `EpCompositeSlice`. Append-on-empty / reject-on-seen, per
// composite entity: the decision read is scoped to one `{environment,
// resourceName}` composite, so a fresh resource sees `Absent` and appends, while
// a duplicate of the same composite key sees `Added` and is rejected.
//
// `TouchResource` is the read-back probe: it requires the slice to have already
// observed its own `ResourceAdded` (state `Added`) to succeed, so it exercises
// the composite read-matching-its-own-write invariant.

type state =
  | Absent
  | Added

let initialState = Absent

let evolve = (_state, event: EpCompositeSlice.consumedEvent) =>
  switch event {
  | ResourceAdded(_) => Added
  | ResourceTouched(_) => Added
  }

let decide = (state, command: EpCompositeSlice.command): result<
  array<EpCompositeSlice.event>,
  EpCompositeSlice.error,
> =>
  switch (state, command) {
  | (Added, AddResource(_)) => Error(AlreadyAdded)
  | (Absent, AddResource({environment, resourceName})) =>
    Ok([ResourceAdded({environment, resourceName})])
  | (Added, TouchResource({environment, resourceName})) =>
    Ok([ResourceTouched({environment, resourceName})])
  | (Absent, TouchResource(_)) => Error(NotFound)
  }

let moduleUrl = "ep-test://EpCompositeSliceBehavior"
