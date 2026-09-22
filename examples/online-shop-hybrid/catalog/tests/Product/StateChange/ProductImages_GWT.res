// The host's own rules. The set's rules — idempotent attach and remove, the
// primary, the caption — are the trait's, asserted in
// `ProductImagesConformance_GWT.res`.

@@reventless.gwt

open CatalogExamples

let img = "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"

describe("ProductImages StateChangeSlice", () => {
  // scenario-id: 399a9071-592d-4474-9417-cb7e489ec6c1
  test("non-existent product returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(AttachProductImage({productId: p1, productImage: img}))
    ->thenError(ProductNotFound)
  )

  // scenario-id: 939928ec-6d97-485d-9d1c-e0f04abacdcb
  test("a listed product takes attachments", () =>
    givenEvents([ProductAdded])
    ->whenCmd(AttachProductImage({productId: p1, productImage: img}))
    ->thenEvents([
      ProductImageAttached({productId: p1, productImage: img}),
      ProductEffectiveImageChanged({productId: p1, productImage: img}),
    ])
  )

  // scenario-id: 42fcb042-a85e-476e-a7f1-8c66807f7e03
  test("a listed product releases them", () =>
    givenEvents([ProductAdded, ProductImageAttached({productImage: img})])
    ->whenCmd(RemoveProductImage({productId: p1, productImage: img}))
    ->thenEvents([
      ProductImageRemoved({productId: p1, productImage: img}),
      ProductEffectiveImageChanged({productId: p1}),
    ])
  )

  // scenario-id: 9b4df972-605c-4e40-afcb-e6f79e4b0635
  test("a listed product chooses its primary", () =>
    givenEvents([
      ProductAdded,
      ProductImageAttached({productImage: img}),
      ProductImageAttached({
        productImage: sideImage,
      }),
    ])
    ->whenCmd(
      SetPrimaryProductImage({
        productId: p1,
        productImage: sideImageRef,
      }),
    )
    ->thenEvents([
      ProductPrimaryImageSet({
        productId: p1,
        productImage: sideImage,
      }),
      ProductEffectiveImageChanged({
        productId: p1,
        productImage: sideImage,
      }),
    ])
  )

  // scenario-id: e14d07ae-bcaf-4f9c-acf2-95b7a626cbc3
  test("a listed product captions a member", () =>
    givenEvents([ProductAdded, ProductImageAttached({productImage: img})])
    ->whenCmd(SetProductImageAltText({productId: p1, productImage: img, altText: frontAlt}))
    ->thenEvent(ProductImageAltTextSet({productId: p1, productImage: img, altText: frontAlt}))
  )

  // scenario-id: 8c2870ec-9add-4664-a385-4857a02025f3
  test("an archived product still takes attachments", () =>
    givenEvents([ProductAdded, ProductArchived])
    ->whenCmd(AttachProductImage({productId: p1, productImage: img}))
    ->thenEvents([
      ProductImageAttached({productId: p1, productImage: img}),
      ProductEffectiveImageChanged({productId: p1, productImage: img}),
    ])
  )

  // scenario-id: 56c3f122-cf05-4f2a-8426-10ddc03ca38d
  test("an archived product still releases attachments", () =>
    givenEvents([ProductAdded, ProductImageAttached({productImage: img}), ProductArchived])
    ->whenCmd(RemoveProductImage({productId: p1, productImage: img}))
    ->thenEvents([
      ProductImageRemoved({productId: p1, productImage: img}),
      ProductEffectiveImageChanged({productId: p1}),
    ])
  )

  // scenario-id: 0a6508ca-1c62-4f90-bc30-9bf5e071bf5d
  test("an archived product chooses its primary", () =>
    givenEvents([
      ProductAdded,
      ProductImageAttached({productImage: img}),
      ProductImageAttached({
        productImage: sideImage,
      }),
      ProductArchived,
    ])
    ->whenCmd(
      SetPrimaryProductImage({
        productId: p1,
        productImage: sideImageRef,
      }),
    )
    ->thenEvents([
      ProductPrimaryImageSet({
        productId: p1,
        productImage: sideImage,
      }),
      ProductEffectiveImageChanged({
        productId: p1,
        productImage: sideImage,
      }),
    ])
  )

  // scenario-id: a2820285-de0a-4107-928a-676621af7c26
  test("an archived product captions a member", () =>
    givenEvents([ProductAdded, ProductImageAttached({productImage: img}), ProductArchived])
    ->whenCmd(SetProductImageAltText({productId: p1, productImage: img, altText: frontAlt}))
    ->thenEvent(ProductImageAltTextSet({productId: p1, productImage: img, altText: frontAlt}))
  )

  // scenario-id: 0a4e929c-c371-4347-b2ee-ed873da8ffe1
  test("a discontinued product refuses them", () =>
    givenEvents([ProductAdded, ProductDiscontinued])
    ->whenCmd(AttachProductImage({productId: p1, productImage: img}))
    ->thenError(ProductIsDiscontinued)
  )
})
