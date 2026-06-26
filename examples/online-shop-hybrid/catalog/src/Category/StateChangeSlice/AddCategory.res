// AddCategory StateChangeSlice.
// Handles the AddCategory command; rejects duplicate creation via DCB optimistic concurrency.
@@reventless.spec

@schema
type consumedEvent =
  | CategoryAdded
  | CategoryArchived

@schema
type command = AddCategory({categoryId: string, name: string})

@schema
type error = CategoryAlreadyExists

// `categoryId` is this slice's partition (the sole tag is auto-selected). That
// `AddProduct` reads it cross-partition is *inferred* from the slice graph — no
// `@crossPartition` needed here.
@schema
type event = CategoryAdded({categoryId: string, name: string})
