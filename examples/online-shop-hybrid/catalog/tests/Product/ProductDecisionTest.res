// Pure unit tests for Product StateChangeSlice decision logic.
// Tests evolve and decide functions for AddProduct, ChangeProductName,
// ChangeProductDescription, and ChangeProductPrice synchronously.

open Jest
open Expect

describe("AddProduct:", () => {
  describe("evolve", () => {
    test("ProductAdded sets exists=true", () =>
      expect(
        AddProduct_Behavior.evolve(
          AddProduct_Behavior.initialState,
          AddProduct.ProductAdded,
        ),
      )->toEqual({AddProduct_Behavior.exists: true})
    )
  })

  describe("decide", () => {
    test("on non-existent product produces ProductAdded", () =>
      expect(
        AddProduct_Behavior.decide(
          AddProduct_Behavior.initialState,
          AddProduct.AddProduct({
            productId: "p1",
            name: "Laptop",
            description: "A laptop",
            price: 999.99,
          }),
        ),
      )->toEqual(
        Ok([
          AddProduct.ProductAdded({
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
        AddProduct_Behavior.decide(
          {AddProduct_Behavior.exists: true},
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
  let existingState: ChangeProductName_Behavior.state = {exists: true, currentName: "Laptop"}

  describe("evolve", () => {
    test("ProductAdded sets exists=true and currentName", () =>
      expect(
        ChangeProductName_Behavior.evolve(
          ChangeProductName_Behavior.initialState,
          ChangeProductName.ProductAdded({name: "Laptop"}),
        ),
      )->toEqual({ChangeProductName_Behavior.exists: true, currentName: "Laptop"})
    )

    test("ProductNameChanged updates currentName", () =>
      expect(
        ChangeProductName_Behavior.evolve(
          existingState,
          ChangeProductName.ProductNameChanged({name: "Gaming Laptop"}),
        ),
      )->toEqual({ChangeProductName_Behavior.exists: true, currentName: "Gaming Laptop"})
    )
  })

  describe("decide", () => {
    test("on non-existent product returns ProductNotFound", () =>
      expect(
        ChangeProductName_Behavior.decide(
          ChangeProductName_Behavior.initialState,
          ChangeProductName.ChangeProductName({productId: "p1", name: "Gaming Laptop"}),
        ),
      )->toEqual(Error(ChangeProductName.ProductNotFound))
    )

    test("same name produces no events (idempotent)", () =>
      expect(
        ChangeProductName_Behavior.decide(
          existingState,
          ChangeProductName.ChangeProductName({productId: "p1", name: "Laptop"}),
        ),
      )->toEqual(Ok([]))
    )

    test("new name produces ProductNameChanged", () =>
      expect(
        ChangeProductName_Behavior.decide(
          existingState,
          ChangeProductName.ChangeProductName({productId: "p1", name: "Gaming Laptop"}),
        ),
      )->toEqual(Ok([ChangeProductName.ProductNameChanged({productId: "p1", name: "Gaming Laptop"})]))
    )
  })
})

describe("ChangeProductDescription:", () => {
  let existingState: ChangeProductDescription_Behavior.state = {
    exists: true,
    currentDescription: "A laptop",
  }

  describe("decide", () => {
    test("on non-existent product returns ProductNotFound", () =>
      expect(
        ChangeProductDescription_Behavior.decide(
          ChangeProductDescription_Behavior.initialState,
          ChangeProductDescription.ChangeProductDescription({
            productId: "p1",
            description: "A high-end laptop",
          }),
        ),
      )->toEqual(Error(ChangeProductDescription.ProductNotFound))
    )

    test("same description produces no events (idempotent)", () =>
      expect(
        ChangeProductDescription_Behavior.decide(
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
        ChangeProductDescription_Behavior.decide(
          existingState,
          ChangeProductDescription.ChangeProductDescription({
            productId: "p1",
            description: "A high-end laptop",
          }),
        ),
      )->toEqual(
        Ok([
          ChangeProductDescription.ProductDescriptionChanged({
            productId: "p1",
            description: "A high-end laptop",
          }),
        ]),
      )
    )
  })
})

describe("ChangeProductPrice:", () => {
  let existingState: ChangeProductPrice_Behavior.state = {exists: true, currentPrice: 999.99}

  describe("decide", () => {
    test("on non-existent product returns ProductNotFound", () =>
      expect(
        ChangeProductPrice_Behavior.decide(
          ChangeProductPrice_Behavior.initialState,
          ChangeProductPrice.ChangeProductPrice({productId: "p1", price: 899.99}),
        ),
      )->toEqual(Error(ChangeProductPrice.ProductNotFound))
    )

    test("same price produces no events (idempotent)", () =>
      expect(
        ChangeProductPrice_Behavior.decide(
          existingState,
          ChangeProductPrice.ChangeProductPrice({productId: "p1", price: 999.99}),
        ),
      )->toEqual(Ok([]))
    )

    test("new price produces ProductPriceChanged", () =>
      expect(
        ChangeProductPrice_Behavior.decide(
          existingState,
          ChangeProductPrice.ChangeProductPrice({productId: "p1", price: 899.99}),
        ),
      )->toEqual(Ok([ChangeProductPrice.ProductPriceChanged({productId: "p1", price: 899.99})]))
    )
  })
})
