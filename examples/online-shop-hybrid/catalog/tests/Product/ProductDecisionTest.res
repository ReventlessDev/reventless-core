// Pure unit tests for Product StateChangeSlice decision logic.
// Tests reduce and decide functions for AddProduct, ChangeProductName,
// ChangeProductDescription, and ChangeProductPrice synchronously.

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
          CatalogEventLog.ProductDemandRecorded({productId: "p1", orderId: "ord-1"}),
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

describe("ChangeProductName:", () => {
  let existingModel: ChangeProductName.decisionModel = {exists: true, currentName: "Laptop"}

  describe("reduce", () => {
    test("ProductAdded sets exists=true and currentName", () =>
      expect(
        ChangeProductName.reduce(
          ChangeProductName.initialDecisionModel,
          CatalogEventLog.ProductAdded({
            productId: "p1",
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        ),
      )->toEqual({ChangeProductName.exists: true, currentName: "Laptop"})
    )

    test("ProductNameChanged updates currentName", () =>
      expect(
        ChangeProductName.reduce(
          existingModel,
          CatalogEventLog.ProductNameChanged({productId: "p1", name: "Gaming Laptop"}),
        ),
      )->toEqual({ChangeProductName.exists: true, currentName: "Gaming Laptop"})
    )
  })

  describe("decide", () => {
    test("on non-existent product returns ProductNotFound", () =>
      expect(
        ChangeProductName.decide(
          ChangeProductName.initialDecisionModel,
          ChangeProductName.ChangeProductName({productId: "p1", name: "Gaming Laptop"}),
        ),
      )->toEqual(Error(ChangeProductName.ProductNotFound))
    )

    test("same name produces no events (idempotent)", () =>
      expect(
        ChangeProductName.decide(
          existingModel,
          ChangeProductName.ChangeProductName({productId: "p1", name: "Laptop"}),
        ),
      )->toEqual(Ok([]))
    )

    test("new name produces ProductNameChanged", () =>
      expect(
        ChangeProductName.decide(
          existingModel,
          ChangeProductName.ChangeProductName({productId: "p1", name: "Gaming Laptop"}),
        ),
      )->toEqual(Ok([CatalogEventLog.ProductNameChanged({productId: "p1", name: "Gaming Laptop"})]))
    )
  })
})

describe("ChangeProductDescription:", () => {
  let existingModel: ChangeProductDescription.decisionModel = {
    exists: true,
    currentDescription: "A laptop",
  }

  describe("decide", () => {
    test("on non-existent product returns ProductNotFound", () =>
      expect(
        ChangeProductDescription.decide(
          ChangeProductDescription.initialDecisionModel,
          ChangeProductDescription.ChangeProductDescription({
            productId: "p1",
            description: "A high-end laptop",
          }),
        ),
      )->toEqual(Error(ChangeProductDescription.ProductNotFound))
    )

    test("same description produces no events (idempotent)", () =>
      expect(
        ChangeProductDescription.decide(
          existingModel,
          ChangeProductDescription.ChangeProductDescription({
            productId: "p1",
            description: "A laptop",
          }),
        ),
      )->toEqual(Ok([]))
    )

    test("new description produces ProductDescriptionChanged", () =>
      expect(
        ChangeProductDescription.decide(
          existingModel,
          ChangeProductDescription.ChangeProductDescription({
            productId: "p1",
            description: "A high-end laptop",
          }),
        ),
      )->toEqual(
        Ok([
          CatalogEventLog.ProductDescriptionChanged({
            productId: "p1",
            description: "A high-end laptop",
          }),
        ]),
      )
    )
  })
})

describe("ChangeProductPrice:", () => {
  let existingModel: ChangeProductPrice.decisionModel = {exists: true, currentPrice: 999.99}

  describe("decide", () => {
    test("on non-existent product returns ProductNotFound", () =>
      expect(
        ChangeProductPrice.decide(
          ChangeProductPrice.initialDecisionModel,
          ChangeProductPrice.ChangeProductPrice({productId: "p1", price: 899.99}),
        ),
      )->toEqual(Error(ChangeProductPrice.ProductNotFound))
    )

    test("same price produces no events (idempotent)", () =>
      expect(
        ChangeProductPrice.decide(
          existingModel,
          ChangeProductPrice.ChangeProductPrice({productId: "p1", price: 999.99}),
        ),
      )->toEqual(Ok([]))
    )

    test("new price produces ProductPriceChanged", () =>
      expect(
        ChangeProductPrice.decide(
          existingModel,
          ChangeProductPrice.ChangeProductPrice({productId: "p1", price: 899.99}),
        ),
      )->toEqual(Ok([CatalogEventLog.ProductPriceChanged({productId: "p1", price: 899.99})]))
    )
  })
})
