// Behavior pair for `EpTestSlice`. Append-on-empty / reject-on-seen.

type state = bool

let initialState = false

let evolve = (_state, _event: EpTestSlice.consumedEvent) => true

let decide = (state, command: EpTestSlice.command): result<
  array<EpTestSlice.event>,
  EpTestSlice.error,
> =>
  switch (state, command) {
  | (true, _) => Error(AlreadyAdded)
  | (false, AddWidget({widgetId})) => Ok([WidgetAdded({widgetId: widgetId})])
  }

let moduleUrl = "ep-test://EpTestSliceBehavior"
