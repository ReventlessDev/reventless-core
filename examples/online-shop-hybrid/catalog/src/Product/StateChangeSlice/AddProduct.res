// AddProduct StateChangeSlice.
// Rejects duplicate creation and validates that the referenced category exists
// and is active.

@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({productId: string})
  | CategoryAdded({categoryId: string})
  | CategoryArchived({categoryId: string})

@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"])) AddProduct({
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
