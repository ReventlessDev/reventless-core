// AddProduct StateChangeSlice.
// Rejects duplicate creation and validates that the referenced category exists
// and is active.

@@reventless.spec

// The category's `name` is read as well as its id, so a product can record what
// its category was called when it was added. A rename *before* the addition is
// therefore captured; one after it is not, which is the event-sourced answer: a
// projection keyed by `productId` cannot rewrite every row of a renamed category,
// so the tempting version of this is not the cheap one.
@schema
type consumedEvent =
  | ProductAdded({productId: string})
  | CategoryAdded({categoryId: string, name: string})
  | CategoryRenamed({categoryId: string, name: string})
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
      // What the category was called at the moment this product was added.
      // Optional because every product added before this field existed carries no
      // key, which is what makes adding it cost the log nothing.
      categoryName?: string,
    })
