// ChangeProductName StateChangeSlice.
// Requires product to exist; idempotent when name is unchanged.

@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({name: string})
  | ProductNameChanged({name: string})

@schema
type command = @authorize(AllowGroups(["Admin"])) ChangeProductName({productId: string, name: string})

@schema
type error = ProductNotFound

@schema
type event =
  | ProductNameChanged({productId: string, name: string})
