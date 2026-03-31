# BehaviorTest DSL

## Setup

Include the BehaviorTest module in your test file:

```rescript
open Product
include ReventlessInMemory.BehaviorTest.Make(Product, ProductBehavior)
```

This provides `givenEvents`, `whenCmd`, `thenEvent`, `thenError`, `thenNoEvents`.

## Pattern: Given/When/Then

```rescript
describe("ProductBehavior:", () => {
  // Happy path: new entity
  test("Add on new aggregate produces Added", () =>
    givenEvents([])
    ->whenCmd(Add({name: "Laptop", description: "A laptop", price: 999.99}))
    ->thenEvent(Added({name: "Laptop", description: "A laptop", price: 999.99}))
  )

  // Error: duplicate create
  test("Add on existing returns error", () =>
    givenEvents([Added({name: "Laptop", description: "A laptop", price: 999.99})])
    ->whenCmd(Add({name: "Phone", description: "A phone", price: 499.99}))
    ->thenError(ProductAlreadyExists)
  )

  // Idempotency: no change
  test("UpdateName with same name produces no events", () =>
    givenEvents([Added({name: "Laptop", description: "A laptop", price: 999.99})])
    ->whenCmd(UpdateName({name: "Laptop"}))
    ->thenNoEvents
  )

  // Field update
  test("UpdateName produces NameUpdated", () =>
    givenEvents([Added({name: "Laptop", description: "A laptop", price: 999.99})])
    ->whenCmd(UpdateName({name: "Gaming Laptop"}))
    ->thenEvent(NameUpdated({name: "Gaming Laptop"}))
  )

  // Error: entity not found
  test("UpdateName on non-existent returns error", () =>
    givenEvents([])
    ->whenCmd(UpdateName({name: "Laptop"}))
    ->thenError(ProductNotFound)
  )
})
```

## Test Categories

1. **Happy path** — new entity, successful command → event
2. **Guard conditions** — duplicate create, entity not found, invalid state
3. **Idempotency** — same-value update → `Ok([])`
4. **Multi-event** — command producing multiple events
5. **State evolution** — command depending on accumulated state from multiple events
