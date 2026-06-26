// AddProduct StateChangeSlice.
// Handles the AddProduct command; rejects duplicate creation via DCB optimistic
// concurrency AND validates that the referenced category exists and is active.
//
// The cross-partition read is now *inferred* — no `@crossPartition`. `productId`
// is this slice's partition (it owns `ProductAdded`); `categoryId` is a foreign
// reference (Category owns it), so the framework reads the category's lifecycle
// (`CategoryAdded` / `CategoryArchived`) by `categoryId` in its own clause and
// treats `categoryId` as *payload* on the emitted `ProductAdded`. No sibling
// products are swept into the category read, so the decision model only needs a
// plain "does this product already exist?" check.

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
      // Foreign reference (Category owns it). Inferred as a cross-partition read
      // key and payload on this event — no annotation needed.
      categoryId: string,
    })
