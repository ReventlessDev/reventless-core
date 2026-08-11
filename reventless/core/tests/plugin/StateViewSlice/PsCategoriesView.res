// Test fixture for the published singular query field.
// "Categories" is the name a naive "strip a trailing s" derivation gets wrong
// (`Categorie`), so it is the one that proves `singleQueryField` comes from
// `Api_Naming` rather than from a rule re-invented at the consumer.

@@reventless.spec("Categories")

@schema
type consumedEvent = CategoryAdded({categoryId: string, name: string})

@schema
type state = {categoryId: string, name: string}

let project = ({event}: Reventless.StateViewSlice.consumed<consumedEvent>) =>
  switch event {
  | CategoryAdded({categoryId, name}) => [Set(categoryId, {categoryId, name})]
  }
