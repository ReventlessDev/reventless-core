// AddProduct StateChangeSlice.
// Rejects duplicate creation and validates that the referenced category exists
// and is active.

@@reventless.spec

// A category is read for whether it exists and is live, which is the whole of
// what this command decides on. What it is *called* is not read: the emitted
// event carries the reference, and a reader resolves the name from the category
// itself, where a rename is immediately visible.
@schema
type consumedEvent =
  | ProductAdded({productId: string})
  | CategoryAdded({categoryId: string})
  | CategoryArchived({categoryId: string})

@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  AddProduct({
      // Two *Id fields (productId + categoryId) — @partitionTag picks the storage partition.
      @partitionTag productId: string,
      name: string,
      description: string,
      price: Reventless.Money.t,
      // Images are attached afterwards, through `ProductImages` — a creation
      // that also attaches would be two facts in one event.
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
      price: Reventless.Money.t,
      categoryId: string,
    })
