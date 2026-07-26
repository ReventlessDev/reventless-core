// ChangeProductImage StateChangeSlice.
// Requires product to exist; idempotent when the image is unchanged.

@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({imageUrl: string})
  | ProductImageChanged({imageUrl: string})

@schema
type command =
  ChangeProductImage({productId: string, imageUrl: string})

@schema
type error = ProductNotFound

@schema
type event =
  | ProductImageChanged({
      productId: string,
      imageUrl: string,
    })
