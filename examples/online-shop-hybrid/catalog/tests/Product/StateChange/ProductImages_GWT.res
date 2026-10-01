// The host's own rules. The set's rules — idempotent attach and remove, the
// primary, the caption — are the trait's, asserted in
// `ProductImagesConformance_GWT.res`.

@@reventless.gwt

open Catalog_Examples

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

describe("Who may AttachProductImage", () => {
  // scenario-id: cbd4db0d-a33f-4c04-b64a-e9d417328ccc
  test("a Merchandiser may attach a product image", () =>
    givenEvents([ProductAdded])
    ->asCaller(Caller.inRoles([Merchandiser]))
    ->whenCmd(AttachProductImage({productId: p1, productImage: img}))
    ->thenEvents([
      ProductImageAttached({productId: p1, productImage: img}),
      ProductEffectiveImageChanged({productId: p1, productImage: img}),
    ])
  )

  // scenario-id: 390a7edc-ce12-48d6-8722-ed6d242df2be
  test("an Admin may attach a product image", () =>
    givenEvents([ProductAdded])
    ->asCaller(Caller.inRoles([Admin]))
    ->whenCmd(AttachProductImage({productId: p1, productImage: img}))
    ->thenEvents([
      ProductImageAttached({productId: p1, productImage: img}),
      ProductEffectiveImageChanged({productId: p1, productImage: img}),
    ])
  )

  // scenario-id: e79cedd2-56cf-4af2-a006-b2ca131d8a80
  test("a shopper may not attach a product image", () =>
    givenEvents([ProductAdded])
    ->asCaller(Caller.owner(shopper))
    ->whenCmd(AttachProductImage({productId: p1, productImage: img}))
    ->thenRefused
  )

  // scenario-id: 4e820975-a1fd-43a4-96b4-424d51c7b95c
  test("an anonymous caller may not attach a product image", () =>
    givenEvents([ProductAdded])
    ->asCaller(Caller.anonymous)
    ->whenCmd(AttachProductImage({productId: p1, productImage: img}))
    ->thenRefused
  )
})

describe("Who may RemoveProductImage", () => {
  // scenario-id: 17606490-372a-42bd-8af8-09648e8d29c6
  test("a Merchandiser may remove a product image", () =>
    givenEvents([ProductAdded, ProductImageAttached({productImage: img})])
    ->asCaller(Caller.inRoles([Merchandiser]))
    ->whenCmd(RemoveProductImage({productId: p1, productImage: img}))
    ->thenEvents([
      ProductImageRemoved({productId: p1, productImage: img}),
      ProductEffectiveImageChanged({productId: p1}),
    ])
  )

  // scenario-id: d4142113-2fc9-4c88-b813-ec53318201c8
  test("an Admin may remove a product image", () =>
    givenEvents([ProductAdded, ProductImageAttached({productImage: img})])
    ->asCaller(Caller.inRoles([Admin]))
    ->whenCmd(RemoveProductImage({productId: p1, productImage: img}))
    ->thenEvents([
      ProductImageRemoved({productId: p1, productImage: img}),
      ProductEffectiveImageChanged({productId: p1}),
    ])
  )

  // scenario-id: b746119c-e521-42ea-8a62-9864b70d95b3
  test("a shopper may not remove a product image", () =>
    givenEvents([ProductAdded, ProductImageAttached({productImage: img})])
    ->asCaller(Caller.owner(shopper))
    ->whenCmd(RemoveProductImage({productId: p1, productImage: img}))
    ->thenRefused
  )

  // scenario-id: f2f8bc52-4f59-4e0f-894b-23a0d3a5a2f7
  test("an anonymous caller may not remove a product image", () =>
    givenEvents([ProductAdded, ProductImageAttached({productImage: img})])
    ->asCaller(Caller.anonymous)
    ->whenCmd(RemoveProductImage({productId: p1, productImage: img}))
    ->thenRefused
  )
})

describe("Who may SetPrimaryProductImage", () => {
  // scenario-id: 882944d0-2498-414a-82d7-1a4c978ca326
  test("a Merchandiser may choose a product's primary image", () =>
    givenEvents([
      ProductAdded,
      ProductImageAttached({productImage: img}),
      ProductImageAttached({productImage: sideImage}),
    ])
    ->asCaller(Caller.inRoles([Merchandiser]))
    ->whenCmd(SetPrimaryProductImage({productId: p1, productImage: sideImageRef}))
    ->thenEvents([
      ProductPrimaryImageSet({productId: p1, productImage: sideImage}),
      ProductEffectiveImageChanged({productId: p1, productImage: sideImage}),
    ])
  )

  // scenario-id: 850e46c2-737f-4fd1-b088-5bd541fc2a42
  test("an Admin may choose a product's primary image", () =>
    givenEvents([
      ProductAdded,
      ProductImageAttached({productImage: img}),
      ProductImageAttached({productImage: sideImage}),
    ])
    ->asCaller(Caller.inRoles([Admin]))
    ->whenCmd(SetPrimaryProductImage({productId: p1, productImage: sideImageRef}))
    ->thenEvents([
      ProductPrimaryImageSet({productId: p1, productImage: sideImage}),
      ProductEffectiveImageChanged({productId: p1, productImage: sideImage}),
    ])
  )

  // scenario-id: 38bf2639-636e-484a-971f-92888b49e850
  test("a shopper may not choose a product's primary image", () =>
    givenEvents([
      ProductAdded,
      ProductImageAttached({productImage: img}),
      ProductImageAttached({productImage: sideImage}),
    ])
    ->asCaller(Caller.owner(shopper))
    ->whenCmd(SetPrimaryProductImage({productId: p1, productImage: sideImageRef}))
    ->thenRefused
  )

  // scenario-id: 077c7398-42a7-4aec-ba83-d817c94f6fcd
  test("an anonymous caller may not choose a product's primary image", () =>
    givenEvents([
      ProductAdded,
      ProductImageAttached({productImage: img}),
      ProductImageAttached({productImage: sideImage}),
    ])
    ->asCaller(Caller.anonymous)
    ->whenCmd(SetPrimaryProductImage({productId: p1, productImage: sideImageRef}))
    ->thenRefused
  )
})

describe("Who may SetProductImageAltText", () => {
  // scenario-id: e733e3fa-9924-4101-8554-e7d9dcbe087c
  test("a Merchandiser may caption a product image", () =>
    givenEvents([ProductAdded, ProductImageAttached({productImage: img})])
    ->asCaller(Caller.inRoles([Merchandiser]))
    ->whenCmd(SetProductImageAltText({productId: p1, productImage: img, altText: frontAlt}))
    ->thenEvent(ProductImageAltTextSet({productId: p1, productImage: img, altText: frontAlt}))
  )

  // scenario-id: d7be6c4a-edc3-4239-90b3-61623a94b95f
  test("an Admin may caption a product image", () =>
    givenEvents([ProductAdded, ProductImageAttached({productImage: img})])
    ->asCaller(Caller.inRoles([Admin]))
    ->whenCmd(SetProductImageAltText({productId: p1, productImage: img, altText: frontAlt}))
    ->thenEvent(ProductImageAltTextSet({productId: p1, productImage: img, altText: frontAlt}))
  )

  // scenario-id: 1dd6dc06-303d-446e-a5e1-f653f2cfa944
  test("a shopper may not caption a product image", () =>
    givenEvents([ProductAdded, ProductImageAttached({productImage: img})])
    ->asCaller(Caller.owner(shopper))
    ->whenCmd(SetProductImageAltText({productId: p1, productImage: img, altText: frontAlt}))
    ->thenRefused
  )

  // scenario-id: 62779937-b3b4-4e35-8d47-5c2b86b454c4
  test("an anonymous caller may not caption a product image", () =>
    givenEvents([ProductAdded, ProductImageAttached({productImage: img})])
    ->asCaller(Caller.anonymous)
    ->whenCmd(SetProductImageAltText({productId: p1, productImage: img, altText: frontAlt}))
    ->thenRefused
  )
})
