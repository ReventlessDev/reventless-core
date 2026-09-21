// An identity-typed field is an id whatever it is called: `buyer: CustomerId.t`
// must reach the SDL as `ID!` and carry its key on the JSON Schema, or a field
// that is neither tagged nor referenced loses its id-ness on the wire.

open JestGlobals

module OrderId = Reventless.Id.Make({
  let key = "orderId"
})
module CustomerId = Reventless.Id.Make({
  let key = "customerId"
})

@schema
type order = {
  buyer: CustomerId.t,
  previous: option<OrderId.t>,
  related: array<OrderId.t>,
  note: string,
}

let property = (json: JSON.t, name: string): option<JSON.t> =>
  json
  ->JSON.Decode.object
  ->Option.flatMap(o => o->Dict.get("properties"))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(p => p->Dict.get(name))

let key = (json: option<JSON.t>, name: string): option<JSON.t> =>
  json->Option.flatMap(JSON.Decode.object)->Option.flatMap(o => o->Dict.get(name))

describe("the identity semantic on the JSON Schema", () => {
  let json = SuryToJsonSchema.deriveObjectSchema(orderSchema->S.castToUnknown)

  testSync("names the semantic and its key", () => {
    let buyer = json->property("buyer")
    expect(buyer->key("x-reventless-semantic"))->toEqual(Some(JSON.Encode.string("identity")))
    expect(buyer->key("x-reventless-semantic-target"))->toEqual(
      Some(JSON.Encode.object(Dict.fromArray([("key", JSON.Encode.string("customerId"))]))),
    )
  })

  testSync("reaches an array's elements", () =>
    expect(
      json
      ->property("related")
      ->key("items")
      ->key("x-reventless-semantic-target")
      ->key("key"),
    )->toEqual(Some(JSON.Encode.string("orderId")))
  )

  testSync("leaves a plain string alone", () =>
    expect(json->property("note")->key("x-reventless-semantic"))->toEqual(None)
  )
})

describe("the identity semantic in the SDL", () => {
  let sdl =
    GraphQL_FragmentGenerator.deriveObjectTypeWithNested(
      ~typeName="Ordering_Order",
      ~includeIdParam=false,
      orderSchema->S.castToUnknown,
    )->Array.join("\n")

  testSync("an identity field not named `*Id` is an ID", () =>
    expect(sdl->String.includes("buyer: ID!"))->toBe(true)
  )

  testSync("an optional identity keeps its optionality", () =>
    expect(sdl->String.includes("previous: ID\n"))->toBe(true)
  )

  testSync("an array of identities is a list of IDs", () =>
    expect(sdl->String.includes("related: [ID!]!"))->toBe(true)
  )
})
