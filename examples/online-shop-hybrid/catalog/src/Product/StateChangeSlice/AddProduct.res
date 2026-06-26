// AddProduct StateChangeSlice.
// Handles the AddProduct command; rejects duplicate creation via DCB optimistic
// concurrency AND validates that the referenced category exists and is active.
//
// `productId` is the partition tag; `categoryId` adds a second tag clause so the
// decision query also fetches the category's lifecycle events. Because the
// category clause also returns sibling `ProductAdded` events sharing the same
// `categoryId` tag, `ProductAdded` carries `productId` so the decision model can
// ask "is THIS product already added?" without being confused by siblings.

@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({productId: string})
  | CategoryAdded({categoryId: string})
  | CategoryArchived({categoryId: string})

@schema
type command =
  | AddProduct({
      @partitionTag productId: string,
      name: string,
      description: string,
      price: float,
      @ref("Categories") categoryId: string,
    })

@schema
type error =
  | ProductAlreadyExists
  | CategoryNotFound

@schema
type event =
  | ProductAdded({
      @partitionTag productId: string,
      name: string,
      description: string,
      price: float,
      // Secondary cross-partition tag: AddProduct's decision model reads the
      // category's lifecycle (a different partition) by this key, so it must be
      // @crossPartition on every event that carries it (here and on the Category
      // slices). Without it the decision query AND-s productId+categoryId into
      // one clause and never sees CategoryAdded → CategoryNotFound always.
      @crossPartition categoryId: string,
    })
