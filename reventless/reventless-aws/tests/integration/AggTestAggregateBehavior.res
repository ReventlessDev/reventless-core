// Behavior pair for `AggTestAggregate`. Create-once / reject-on-seen.

type state = NotCreated | Active

let initialState = NotCreated

let evolve = (_state, _event: AggTestAggregate.event) => Active

let decide = (state, command: AggTestAggregate.command): result<
  array<AggTestAggregate.event>,
  AggTestAggregate.error,
> =>
  switch (state, command) {
  | (Active, _) => Error(AlreadyExists)
  | (NotCreated, Add({name})) => Ok([Added({name: name})])
  }

let moduleUrl = "agg-test://AggTestAggregateBehavior"
