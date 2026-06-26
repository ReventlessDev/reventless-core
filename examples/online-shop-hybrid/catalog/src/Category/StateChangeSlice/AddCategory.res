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

// `categoryId` is `@crossPartition` because `AddProduct` reads CategoryAdded
// from its (product-partitioned) decision model — the scope is a global per-key
// flag, so every event carrying `categoryId` must agree. It remains this slice's
// partition key (the sole tag is auto-selected).
@schema
type event = CategoryAdded({@crossPartition categoryId: string, name: string})
