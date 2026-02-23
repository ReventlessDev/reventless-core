// Pure unit tests for Product StateChangeSlice decision logic.
// Tests reduce and decide functions for AddProduct, UpdateProductName,
// UpdateProductDescription, and UpdateProductPrice synchronously.

open Jest
open Expect

describe("AddProduct:", () => {
  describe("reduce", () => {
    test("ProductAdded sets exists=true", () =>
      expect(
        AddProduct.reduce(
          AddProduct.initialDecisionModel,
          CatalogEventLog.ProductAdded({
            productId: "p1",
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        ),
      )->toEqual({AddProduct.exists: true})
    )

    test("other events do not change model", () =>
      expect(
        AddProduct.reduce(
          AddProduct.initialDecisionModel,
          CatalogEventLog.CategoryAdded({categoryId: "c1", name: "Books"}),
        ),
      )->toEqual(AddProduct.initialDecisionModel)
    )
  })

  describe("decide", () => {
    test("on non-existent product produces ProductAdded", () =>
      expect(
        AddProduct.decide(
          AddProduct.initialDecisionModel,
          AddProduct.AddProduct({
            productId: "p1",
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        ),
      )->toEqual(
        Ok([
          CatalogEventLog.ProductAdded({
            productId: "p1",
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        ]),
      )
    )

    test("on existing product returns ProductAlreadyExists", () =>
      expect(
        AddProduct.decide(
          {AddProduct.exists: true},
          AddProduct.AddProduct({
            productId: "p1",
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        ),
      )->toEqual(Error(AddProduct.ProductAlreadyExists))
    )
  })
})

describe("UpdateProductName:", () => {
  let existingModel: UpdateProductName.decisionModel = {exists: true, currentName: "Laptop"}

  describe("reduce", () => {
    test("ProductAdded sets exists=true and currentName", () =>
      expect(
        UpdateProductName.reduce(
          UpdateProductName.initialDecisionModel,
          CatalogEventLog.ProductAdded({
            productId: "p1",
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        ),
      )->toEqual({UpdateProductName.exists: true, currentName: "Laptop"})
    )

    test("ProductNameUpdated updates currentName", () =>
      expect(
        UpdateProductName.reduce(
          existingModel,
          CatalogEventLog.ProductNameUpdated({productId: "p1", name: "Gaming Laptop"}),
        ),
      )->toEqual({UpdateProductName.exists: true, currentName: "Gaming Laptop"})
    )
  })

  describe("decide", () => {
    test("on non-existent product returns ProductNotFound", () =>
      expect(
        UpdateProductName.decide(
          UpdateProductName.initialDecisionModel,
          UpdateProductName.UpdateProductName({productId: "p1", name: "Gaming Laptop"}),
        ),
      )->toEqual(Error(UpdateProductName.ProductNotFound))
    )

    test("same name produces no events (idempotent)", () =>
      expect(
        UpdateProductName.decide(
          existingModel,
          UpdateProductName.UpdateProductName({productId: "p1", name: "Laptop"}),
        ),
      )->toEqual(Ok([]))
    )

    test("new name produces ProductNameUpdated", () =>
      expect(
        UpdateProductName.decide(
          existingModel,
          UpdateProductName.UpdateProductName({productId: "p1", name: "Gaming Laptop"}),
        ),
      )->toEqual(Ok([CatalogEventLog.ProductNameUpdated({productId: "p1", name: "Gaming Laptop"})]))
    )
  })
})

describe("UpdateProductDescription:", () => {
  let existingModel: UpdateProductDescription.decisionModel = {
    exists: true,
    currentDescription: "A laptop",
  }

  describe("decide", () => {
    test("on non-existent product returns ProductNotFound", () =>
      expect(
        UpdateProductDescription.decide(
          UpdateProductDescription.initialDecisionModel,
          UpdateProductDescription.UpdateProductDescription({
            productId: "p1",
            description: "A high-end laptop",
          }),
        ),
      )->toEqual(Error(UpdateProductDescription.ProductNotFound))
    )

    test("same description produces no events (idempotent)", () =>
      expect(
        UpdateProductDescription.decide(
          existingModel,
          UpdateProductDescription.UpdateProductDescription({
            productId: "p1",
            description: "A laptop",
          }),
        ),
      )->toEqual(Ok([]))
    )

    test("new description produces ProductDescriptionUpdated", () =>
      expect(
        UpdateProductDescription.decide(
          existingModel,
          UpdateProductDescription.UpdateProductDescription({
            productId: "p1",
            description: "A high-end laptop",
          }),
        ),
      )->toEqual(
        Ok([
          CatalogEventLog.ProductDescriptionUpdated({
            productId: "p1",
            description: "A high-end laptop",
          }),
        ]),
      )
    )
  })
})

describe("UpdateProductPrice:", () => {
  let existingModel: UpdateProductPrice.decisionModel = {exists: true, currentPrice: 999.99}

  describe("decide", () => {
    test("on non-existent product returns ProductNotFound", () =>
      expect(
        UpdateProductPrice.decide(
          UpdateProductPrice.initialDecisionModel,
          UpdateProductPrice.UpdateProductPrice({productId: "p1", price: 899.99}),
        ),
      )->toEqual(Error(UpdateProductPrice.ProductNotFound))
    )

    test("same price produces no events (idempotent)", () =>
      expect(
        UpdateProductPrice.decide(
          existingModel,
          UpdateProductPrice.UpdateProductPrice({productId: "p1", price: 999.99}),
        ),
      )->toEqual(Ok([]))
    )

    test("new price produces ProductPriceUpdated", () =>
      expect(
        UpdateProductPrice.decide(
          existingModel,
          UpdateProductPrice.UpdateProductPrice({productId: "p1", price: 899.99}),
        ),
      )->toEqual(Ok([CatalogEventLog.ProductPriceUpdated({productId: "p1", price: 899.99})]))
    )
  })
})
