// AddProduct StateChangeSlice.
// Handles the AddProduct command; rejects duplicate creation via DCB optimistic concurrency.

@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded

@schema
type command =
  | AddProduct({
      productId: string,
      name: string,
      description: string,
      price: float,
    })

@schema
type error = ProductAlreadyExists

@schema
type event =
  | ProductAdded({
      productId: string,
      name: string,
      description: string,
      price: float,
    })
