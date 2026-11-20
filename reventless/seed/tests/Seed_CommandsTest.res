open JestGlobals

// The generated adapter renders a mutation from the API's own description. What
// it must get right is what a hand-written adapter centralizes: enums unquoted,
// input objects nested, ids and numbers by their declared type. What it must
// refuse is everything the API would refuse, before it is sent.

let introspection = JSON.parseOrThrow(`{"__schema": {
  "mutationType": {"name": "Mutation"},
  "types": [
    {"kind": "SCALAR", "name": "ID"}, {"kind": "SCALAR", "name": "String"},
    {"kind": "SCALAR", "name": "Int"}, {"kind": "SCALAR", "name": "Float"},
    {"kind": "ENUM", "name": "Currency", "enumValues": [{"name": "EUR"}, {"name": "USD"}]},
    {"kind": "INPUT_OBJECT", "name": "MoneyInput", "inputFields": [
      {"name": "amount", "type": {"kind": "NON_NULL", "ofType": {"kind": "SCALAR", "name": "Float"}}},
      {"name": "currency", "type": {"kind": "NON_NULL", "ofType": {"kind": "ENUM", "name": "Currency"}}}
    ]},
    {"kind": "INPUT_OBJECT", "name": "Line", "inputFields": [
      {"name": "productId", "type": {"kind": "NON_NULL", "ofType": {"kind": "SCALAR", "name": "ID"}}},
      {"name": "quantity", "defaultValue": "1", "type": {"kind": "NON_NULL", "ofType": {"kind": "SCALAR", "name": "Int"}}}
    ]},
    {"kind": "OBJECT", "name": "Mutation", "fields": [
      {"name": "Shop_AddProduct", "args": [
        {"name": "productId", "type": {"kind": "NON_NULL", "ofType": {"kind": "SCALAR", "name": "ID"}}},
        {"name": "price", "type": {"kind": "NON_NULL", "ofType": {"kind": "INPUT_OBJECT", "name": "MoneyInput"}}},
        {"name": "note", "type": {"kind": "SCALAR", "name": "String"}}
      ]},
      {"name": "Shop_PlaceOrder", "args": [
        {"name": "lines", "type": {"kind": "NON_NULL", "ofType": {"kind": "LIST", "ofType":
          {"kind": "NON_NULL", "ofType": {"kind": "INPUT_OBJECT", "name": "Line"}}}}}
      ]}
    ]}
  ]
}}`)

let commands = Seed_Commands.fromIntrospection(introspection)

let rendered = (field, args) =>
  commands->Seed_Commands.encode(~field, JSON.parseOrThrow(args))->Result.map(Seed_Types.describe)

describe("Seed_Commands.encode:", () => {
  testSync("renders by declared type: ids quoted, an input object nested, its enum bare", () =>
    expect(
      rendered(
        "Shop_AddProduct",
        `{"productId": "p-1", "price": {"amount": 12.5, "currency": "EUR"}}`,
      ),
    )->toEqual(Ok(`Shop_AddProduct(productId: "p-1", price: {amount: 12.5, currency: EUR})`))
  )

  testSync("a list of input objects; an Int stays an Int; a default may be left out", () =>
    expect(
      rendered(
        "Shop_PlaceOrder",
        `{"lines": [{"productId": "p-1", "quantity": 2}, {"productId": "p-2"}]}`,
      ),
    )->toEqual(Ok(`Shop_PlaceOrder(lines: [{productId: "p-1", quantity: 2}, {productId: "p-2"}])`))
  )

  testSync("an optional argument given as null is left out", () =>
    expect(
      rendered(
        "Shop_AddProduct",
        `{"productId": "p-1", "price": {"amount": 1, "currency": "USD"}, "note": null}`,
      ),
    )->toEqual(Ok(`Shop_AddProduct(productId: "p-1", price: {amount: 1, currency: USD})`))
  )

  testSync("refuses what the API would refuse, naming where", () => {
    let refused = (field, args, fragment) =>
      switch rendered(field, args) {
      | Error(message) => expect(message->String.includes(fragment))->toBe(true)
      | Ok(m) => failwith(`expected a refusal, rendered ${m}`)
      }
    refused("Shop_Nope", `{}`, `no mutation "Shop_Nope"`)
    refused("Shop_AddProduct", `{"productId": "p"}`, `"price"`)
    refused(
      "Shop_AddProduct",
      `{"productId": "p", "price": {"amount": 1, "currency": "GBP"}}`,
      "one of EUR, USD",
    )
    refused(
      "Shop_AddProduct",
      `{"productId": "p", "price": {"amount": 1, "currency": "EUR"}, "x": 1}`,
      `no argument "x"`,
    )
    refused("Shop_PlaceOrder", `{"lines": [{"productId": "p", "quantity": 1.5}]}`, "is not a Int")
    refused("Shop_PlaceOrder", `{"lines": {"productId": "p"}}`, "expected a list")
  })
})

describe("Seed_Commands.checkBody:", () => {
  testSync("passes a body the mutation takes, and names what it does not", () => {
    expect(
      commands->Seed_Commands.checkBody(
        ~field="Shop_AddProduct",
        JSON.parseOrThrow(`{"productId": "p", "price": {"amount": 1, "currency": "EUR"}}`),
      ),
    )->toEqual(Ok())
    switch commands->Seed_Commands.checkBody(
      ~field="Shop_AddProduct",
      JSON.parseOrThrow(`{"productId": "p", "price": {"amount": 1, "currency": "eur"}}`),
    ) {
    | Error(message) => expect(message->String.includes("one of EUR, USD"))->toBe(true)
    | Ok() => failwith("expected a refusal")
    }
  })
})
