@@reventless.gwt

open Catalog_Examples

let added = Added({
  name: "Laptop",
  description: "A laptop",
  price: 999.99,
  imageUrl: "/productImages/laptop.jpg",
})

describe("Product Behavior", () => {
  // scenario-id: 6126c93a-ba4e-4ce0-8d8e-654cf64cd8ba
  test("Add on new aggregate produces Added", () =>
    givenEvents([])
    ->whenCmd(
      Add({
        name: laptop,
        description: laptopDescription,
        price: 999.99,
        imageUrl: laptopImage,
      }),
    )
    ->thenEvent(added)
  )

  // scenario-id: d26cb18d-cb83-4dfd-8c5c-437ba96db7fe
  test("Add on existing aggregate returns ProductAlreadyExists", () =>
    givenEvents([added])
    ->whenCmd(
      Add({
        name: "Laptop 2",
        description: "Another",
        price: 1.0,
        imageUrl: "/productImages/laptop-2.jpg",
      }),
    )
    ->thenError(ProductAlreadyExists)
  )

  // scenario-id: dcde1d71-c3c7-4ae8-8d2e-d92ccc9c7d64
  test("UpdateName on non-existent aggregate returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(UpdateName({name: renamedTo}))
    ->thenError(ProductNotFound)
  )

  // scenario-id: f5245b0a-f5d3-4764-b855-357e54d61115
  test("UpdateName on existing product produces NameUpdated", () =>
    givenEvents([added])
    ->whenCmd(UpdateName({name: "Gaming Laptop"}))
    ->thenEvent(NameUpdated({name: "Gaming Laptop"}))
  )

  // scenario-id: 39bf5156-c629-44cd-81bf-34b15a8d86b6
  test("UpdateName to same name produces no events (idempotent)", () =>
    givenEvents([added])->whenCmd(UpdateName({name: laptop}))->thenNoEvent
  )

  // scenario-id: b6864b7c-1040-4080-ad5b-7ffda32911f1
  test("UpdateDescription on non-existent aggregate returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(UpdateDescription({description: "x"}))
    ->thenError(ProductNotFound)
  )

  // scenario-id: 86557de4-56b3-4a05-8927-8cab2f2b35fe
  test("UpdateDescription on existing product produces DescriptionUpdated", () =>
    givenEvents([added])
    ->whenCmd(UpdateDescription({description: "A high-end laptop"}))
    ->thenEvent(DescriptionUpdated({description: "A high-end laptop"}))
  )

  // scenario-id: 7cbdd22a-7839-4e52-9dc0-159f9b0a7b36
  test("UpdateDescription to same description produces no events (idempotent)", () =>
    givenEvents([added])->whenCmd(UpdateDescription({description: laptopDescription}))->thenNoEvent
  )

  // scenario-id: ec726191-3c04-45c4-a22b-fa4838746382
  test("UpdatePrice on non-existent aggregate returns ProductNotFound", () =>
    givenEvents([])->whenCmd(UpdatePrice({price: 1.0}))->thenError(ProductNotFound)
  )

  // scenario-id: 6bda772b-cf1e-4518-8d38-95ec8475de32
  test("UpdatePrice on existing product produces PriceUpdated", () =>
    givenEvents([added])
    ->whenCmd(UpdatePrice({price: 899.99}))
    ->thenEvent(PriceUpdated({price: 899.99}))
  )

  // scenario-id: ab5a7433-da99-4431-9da1-99448de475fd
  test("UpdatePrice to same price produces no events (idempotent)", () =>
    givenEvents([added])->whenCmd(UpdatePrice({price: 999.99}))->thenNoEvent
  )

  // scenario-id: 992cdc4f-957f-4f4a-9838-9ba83f1855b0
  test("UpdateImage on non-existent aggregate returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(UpdateImage({imageUrl: laptopImage}))
    ->thenError(ProductNotFound)
  )

  // scenario-id: ef70aef6-3d4f-4b7f-90ea-2413940879e0
  test("UpdateImage on existing product produces ImageUpdated", () =>
    givenEvents([added])
    ->whenCmd(UpdateImage({imageUrl: "/productImages/laptop-v2.jpg"}))
    ->thenEvent(ImageUpdated({imageUrl: "/productImages/laptop-v2.jpg"}))
  )

  // scenario-id: 13499dc4-536c-491b-b3ff-b0bc9f879b10
  test("UpdateImage to the same ref produces no events (idempotent)", () =>
    givenEvents([added])
    ->whenCmd(UpdateImage({imageUrl: laptopImage}))
    ->thenNoEvent
  )
})
