// The host's own rules. The set's rules — idempotent attach and remove, the
// primary, the caption — are the trait's, asserted in
// `ProductImagesConformance_GWT.res`.

@@reventless.gwt

let img = "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"

describe("ProductImages StateChangeSlice", () => {
  test("non-existent product returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(AttachProductImage({productId: "p1", productImage: img}))
    ->thenError(ProductNotFound)
  )

  test("a listed product takes attachments", () =>
    givenEvents([ProductAdded])
    ->whenCmd(AttachProductImage({productId: "p1", productImage: img}))
    ->thenEvent(ProductImageAttached({productId: "p1", productImage: img}))
  )

  test("a listed product releases them", () =>
    givenEvents([ProductAdded, ProductImageAttached({productImage: img})])
    ->whenCmd(RemoveProductImage({productId: "p1", productImage: img}))
    ->thenEvent(ProductImageRemoved({productId: "p1", productImage: img}))
  )

  test("a listed product chooses its primary", () =>
    givenEvents([
      ProductAdded,
      ProductImageAttached({productImage: img}),
      ProductImageAttached({productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"}),
    ])
    ->whenCmd(
      SetPrimaryProductImage({productId: "p1", productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"}),
    )
    ->thenEvent(
      ProductPrimaryImageSet({productId: "p1", productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"}),
    )
  )

  test("a listed product captions a member", () =>
    givenEvents([ProductAdded, ProductImageAttached({productImage: img})])
    ->whenCmd(SetProductImageAltText({productId: "p1", productImage: img, altText: "front"}))
    ->thenEvent(ProductImageAltTextSet({productId: "p1", productImage: img, altText: "front"}))
  )

  test("an archived product still takes attachments", () =>
    givenEvents([ProductAdded, ProductArchived])
    ->whenCmd(AttachProductImage({productId: "p1", productImage: img}))
    ->thenEvent(ProductImageAttached({productId: "p1", productImage: img}))
  )

  test("an archived product still releases attachments", () =>
    givenEvents([ProductAdded, ProductImageAttached({productImage: img}), ProductArchived])
    ->whenCmd(RemoveProductImage({productId: "p1", productImage: img}))
    ->thenEvent(ProductImageRemoved({productId: "p1", productImage: img}))
  )

  test("an archived product chooses its primary", () =>
    givenEvents([
      ProductAdded,
      ProductImageAttached({productImage: img}),
      ProductImageAttached({productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"}),
      ProductArchived,
    ])
    ->whenCmd(
      SetPrimaryProductImage({productId: "p1", productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"}),
    )
    ->thenEvent(
      ProductPrimaryImageSet({productId: "p1", productImage: "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"}),
    )
  )

  test("an archived product captions a member", () =>
    givenEvents([ProductAdded, ProductImageAttached({productImage: img}), ProductArchived])
    ->whenCmd(SetProductImageAltText({productId: "p1", productImage: img, altText: "front"}))
    ->thenEvent(ProductImageAltTextSet({productId: "p1", productImage: img, altText: "front"}))
  )

  test("a discontinued product refuses them", () =>
    givenEvents([ProductAdded, ProductDiscontinued])
    ->whenCmd(AttachProductImage({productId: "p1", productImage: img}))
    ->thenError(ProductIsDiscontinued)
  )
})
