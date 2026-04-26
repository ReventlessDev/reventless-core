// ChangeProductDescription StateChangeSlice.
// Requires product to exist; idempotent when description is unchanged.
@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({description: string})
  | ProductDescriptionChanged({description: string})

@schema
type command =
  | ChangeProductDescription({productId: string, description: string})

@schema
type error = ProductNotFound

@schema
type event =
  | ProductDescriptionChanged({
      productId: string,
      description: string,
    })
