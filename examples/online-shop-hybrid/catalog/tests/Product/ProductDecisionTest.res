// Pure unit tests for Product StateChangeSlice decision logic.
// Tests evolve and decide functions for AddProduct, ChangeProductName,
// ChangeProductDescription, and ChangeProductPrice synchronously.

open Jest
open Expect

describe("AddProduct:", () => {
  describe("evolve", () => {
    test("ProductAdded sets exists=true", () =>
      expect(
        AddProduct.evolve(
          AddProduct.initialState,
          CatalogEventLog.ProductAdded({
            productId: "p1",
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        ),
      )->toEqual({AddProduct.exists: true})
    )

    test("other events do not change state", () =>
      expect(
        AddProduct.evolve(
          AddProduct.initialState,
          CatalogEventLog.ProductDemandRecorded({productId: "p1", orderId: "ord-1"}),
        ),
      )->toEqual(AddProduct.initialState)
    )
  })

  describe("decide", () => {
    test("on non-existent product produces ProductAdded", () =>
      expect(
        AddProduct.decide(
          AddProduct.initialState,
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
  let existingState: ChangeProductName.state = {exists: true, currentName: "Laptop"}

  describe("evolve", () => {
    test("ProductAdded sets exists=true and currentName", () =>
      expect(
        ChangeProductName.evolve(
          ChangeProductName.initialState,
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
        ChangeProductName.evolve(
          existingState,
          CatalogEventLog.ProductNameChanged({productId: "p1", name: "Gaming Laptop"}),
        ),
      )->toEqual({ChangeProductName.exists: true, currentName: "Gaming Laptop"})
    )
  })

  describe("decide", () => {
    test("on non-existent product returns ProductNotFound", () =>
      expect(
        ChangeProductName.decide(
          ChangeProductName.initialState,
          ChangeProductName.ChangeProductName({productId: "p1", name: "Gaming Laptop"}),
        ),
      )->toEqual(Error(ChangeProductName.ProductNotFound))
    )

    test("same name produces no events (idempotent)", () =>
      expect(
        ChangeProductName.decide(
          existingState,
          ChangeProductName.ChangeProductName({productId: "p1", name: "Laptop"}),
        ),
      )->toEqual(Ok([]))
    )

    test("new name produces ProductNameChanged", () =>
      expect(
        ChangeProductName.decide(
          existingState,
          ChangeProductName.ChangeProductName({productId: "p1", name: "Gaming Laptop"}),
        ),
      )->toEqual(Ok([CatalogEventLog.ProductNameChanged({productId: "p1", name: "Gaming Laptop"})]))
    )
  })
})

describe("ChangeProductDescription:", () => {
  let existingState: ChangeProductDescription.state = {
    exists: true,
    currentDescription: "A laptop",
  }

  describe("decide", () => {
    test("on non-existent product returns ProductNotFound", () =>
      expect(
        ChangeProductDescription.decide(
          ChangeProductDescription.initialState,
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
          existingState,
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
          existingState,
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
  let existingState: ChangeProductPrice.state = {exists: true, currentPrice: 999.99}

  describe("decide", () => {
    test("on non-existent product returns ProductNotFound", () =>
      expect(
        ChangeProductPrice.decide(
          ChangeProductPrice.initialState,
          ChangeProductPrice.ChangeProductPrice({productId: "p1", price: 899.99}),
        ),
      )->toEqual(Error(ChangeProductPrice.ProductNotFound))
    )

    test("same price produces no events (idempotent)", () =>
      expect(
        ChangeProductPrice.decide(
          existingState,
          ChangeProductPrice.ChangeProductPrice({productId: "p1", price: 999.99}),
        ),
      )->toEqual(Ok([]))
    )

    test("new price produces ProductPriceChanged", () =>
      expect(
        ChangeProductPrice.decide(
          existingState,
          ChangeProductPrice.ChangeProductPrice({productId: "p1", price: 899.99}),
        ),
      )->toEqual(Ok([CatalogEventLog.ProductPriceChanged({productId: "p1", price: 899.99})]))
    )
  })
})
