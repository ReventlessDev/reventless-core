// Product aggregate behavior.
// Implements the state machine for adding and updating products.
//
// Snapshotting is enabled (every 50 events): a long-lived product with many
// price/name updates seeds its cold replay from the latest snapshot instead of
// folding full history. See the "Replay cost and snapshots" section of the
// aggregate component docs.

@@reventless.behavior
@@reventless.snapshots(50)

@schema
type state =
  | NotCreated
  | Created({name: string, description: string, price: float})

let initialState = NotCreated

let evolve = (state, event) =>
  switch (state, event) {
  | (NotCreated, Added({name, description, price})) => Created({name, description, price})
  | (Created(_), Added({name, description, price})) => Created({name, description, price})
  | (Created(s), NameUpdated({name})) => Created({...s, name})
  | (Created(s), DescriptionUpdated({description})) => Created({...s, description})
  | (Created(s), PriceUpdated({price})) => Created({...s, price})
  | (NotCreated, _) => state
  }

let decide = (state, command) =>
  switch (state, command) {
  | (NotCreated, Add({name, description, price})) =>
    Ok([Added({name, description, price})])
  | (NotCreated, UpdateName(_)) => Error(ProductNotFound)
  | (NotCreated, UpdateDescription(_)) => Error(ProductNotFound)
  | (NotCreated, UpdatePrice(_)) => Error(ProductNotFound)
  | (Created(_), Add(_)) => Error(ProductAlreadyExists)
  | (Created(s), UpdateName({name})) if name == s.name => Ok([])
  | (Created(_), UpdateName({name})) => Ok([NameUpdated({name: name})])
  | (Created(s), UpdateDescription({description})) if description == s.description => Ok([])
  | (Created(_), UpdateDescription({description})) =>
    Ok([DescriptionUpdated({description: description})])
  | (Created(s), UpdatePrice({price})) if price == s.price => Ok([])
  | (Created(_), UpdatePrice({price})) => Ok([PriceUpdated({price: price})])
  }
