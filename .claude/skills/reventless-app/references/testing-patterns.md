# Testing Patterns

## Aggregate Behavior Test (Unit)

Uses the BehaviorTest DSL: `givenEvents → whenCmd → thenEvent/thenError`

```rescript
// tests/Aggregate/ProductBehaviorTest.res

open Product
include ReventlessInMemory.BehaviorTest.Make(Product, ProductBehavior)

describe("ProductBehavior:", () => {
  test("on new aggregate produces Added", () =>
    givenEvents([])
    ->whenCmd(Add({name: "Laptop", description: "A laptop", price: 999.99}))
    ->thenEvent(Added({name: "Laptop", description: "A laptop", price: 999.99}))
  )

  test("duplicate Add returns ProductAlreadyExists", () =>
    givenEvents([Added({name: "Laptop", description: "A laptop", price: 999.99})])
    ->whenCmd(Add({name: "Phone", description: "A phone", price: 499.99}))
    ->thenError(ProductAlreadyExists)
  )

  test("UpdateName on existing produces NameUpdated", () =>
    givenEvents([Added({name: "Laptop", description: "A laptop", price: 999.99})])
    ->whenCmd(UpdateName({name: "Gaming Laptop"}))
    ->thenEvent(NameUpdated({name: "Gaming Laptop"}))
  )

  test("UpdateName with same name is idempotent", () =>
    givenEvents([Added({name: "Laptop", description: "A laptop", price: 999.99})])
    ->whenCmd(UpdateName({name: "Laptop"}))
    ->thenNoEvents
  )

  test("UpdateName on non-existent returns ProductNotFound", () =>
    givenEvents([])
    ->whenCmd(UpdateName({name: "Laptop"}))
    ->thenError(ProductNotFound)
  )
})
```

## DCB Decision Test (Unit)

Tests the `decide` function directly:

```rescript
// tests/Product/StateChangeSlice/AddProductDecisionTest.res

open Jest
open Expect

describe("AddProduct decide:", () => {
  test("new product produces ProductAdded", () => {
    let result = AddProduct.decide(
      AddProduct.initialState,
      AddProduct.AddProduct({
        productId: "p1",
        name: "Laptop",
        description: "A laptop",
        price: 999.99,
      }),
    )
    expect(result)->toEqual(
      Ok([
        AddProduct.ProductAdded({
          productId: "p1",
          name: "Laptop",
          description: "A laptop",
          price: 999.99,
        }),
      ]),
    )
  })

  test("duplicate product returns error", () => {
    let state = AddProduct.evolve(AddProduct.initialState, AddProduct.ProductAdded)
    let result = AddProduct.decide(
      state,
      AddProduct.AddProduct({
        productId: "p1",
        name: "Phone",
        description: "A phone",
        price: 499.99,
      }),
    )
    expect(result)->toEqual(Error(AddProduct.ProductAlreadyExists))
  })
})
```

## Projection Test

Tests event-to-state transformations:

```rescript
// tests/ReadModel/ProductsProjectionTest.res

open Jest
open Expect
open Reventless.Projection

describe("ProductsProjections:", () => {
  test("Added produces Set", () => {
    let result = ProductsProjections.ProductMapping.project({
      id: "p1",
      meta: testMeta,
      event: Product.Added({name: "Laptop", description: "A laptop", price: 999.99}),
    })
    expect(result)->toEqual(
      Set("p1", {ProductsReadModel.name: "Laptop", description: "A laptop", price: 999.99}),
    )
  })

  test("NameUpdated produces Update", () => {
    let result = ProductsProjections.ProductMapping.project({
      id: "p1",
      meta: testMeta,
      event: Product.NameUpdated({name: "Gaming Laptop"}),
    })
    switch result {
    | Update(id, _fn) => expect(id)->toBe("p1")
    | _ => fail("Expected Update")
    }
  })
})
```

## StateViewSlice Test

```rescript
// tests/Product/StateViewSlice/ProductsViewTest.res

open Jest
open Expect
open Reventless.Projection

describe("ProductsView:", () => {
  test("ProductAdded produces Set", () => {
    let result = ProductsView.project(
      ProductsView.ProductAdded({
        productId: "p1",
        name: "Laptop",
        description: "A laptop",
        price: 999.99,
      }),
    )
    expect(result)->toEqual([
      Set("p1", {
        ProductsView.productId: "p1",
        name: "Laptop",
        description: "A laptop",
        price: 999.99,
      }),
    ])
  })
})
```

## Test File Structure

### Aggregate

```
tests/
├── Aggregate/
│   ├── ProductBehaviorTest.res       # Unit: givenEvents/whenCmd/thenEvent
│   └── CategoryBehaviorTest.res
├── ReadModel/
│   └── ProductsProjectionTest.res    # Unit: event → projection action
└── E2E/
    └── ProductE2ETest.res            # Integration: full command → event pipeline
```

### DCB

```
tests/
├── EntityName/
│   ├── StateChangeSlice/
│   │   ├── AddEntityDecisionTest.res    # Unit: decide function
│   │   └── ChangeFieldDecisionTest.res
│   └── StateViewSlice/
│       └── EntityViewTest.res           # Unit: project function
└── E2E/
    └── EntityE2ETest.res                # Integration: full pipeline
```

## Important Testing Gotchas

1. **`testPromise` is broken** — use native `jestTest` binding for async tests
2. **Jest ESM mode** requires `NODE_OPTIONS='--experimental-vm-modules'`
3. **`@jest/globals`** must be imported for `jest` object in ESM
4. **`Array.getUnsafe(n).field`** — always use intermediate variable
5. **`beforeAllAsync`** needed for DCB E2E tests (handler registration is async)
6. **Round-trip tests** — verify `encode → decode` for all schema types
