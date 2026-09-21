// `Id.Make` gives each identity its own type, a string on the wire, and a schema
// that says which identity it is. sury-ppx must find that schema by convention
// (`OrderId.t` → `OrderId.schema`) although the functor, not the ppx, defines it.

open JestGlobals

module OrderId = Id.Make({
  let key = "orderId"
})
module CustomerId = Id.Make({
  let key = "customerId"
})

@schema
type order = {
  orderId: OrderId.t,
  buyer: CustomerId.t,
  previous: option<OrderId.t>,
  related: array<OrderId.t>,
}

let identityKey = (schema: S.t<unknown>): option<string> =>
  switch Semantic.get(schema) {
  | Some({payload: IdentityOf({key})}) => Some(key)
  | _ => None
  }

describe("Id.Make", () => {
  testSync("an identity is a plain string on the wire", () => {
    let value = {
      orderId: OrderId.make("o-1"),
      buyer: CustomerId.make("c-1"),
      previous: None,
      related: [OrderId.make("o-0")],
    }
    let json = value->Util_Sury.toJson(orderSchema)
    expect(json->JSON.stringify)->toBe(`{"orderId":"o-1","buyer":"c-1","related":["o-0"]}`)
    let back = json->Util_Sury.fromJson(orderSchema)
    expect(back.buyer->CustomerId.toString)->toBe("c-1")
    expect(back.related->Array.map(OrderId.toString))->toEqual(["o-0"])
  })

  testSync("the schema names the identity by its key, whatever the field is called", () => {
    let fields = switch orderSchema->S.castToUnknown {
    | Object({properties}) => properties
    | _ => Dict.make()
    }
    let keyOf = name => fields->Dict.get(name)->Option.flatMap(identityKey)
    expect(keyOf("orderId"))->toEqual(Some("orderId"))
    expect(keyOf("buyer"))->toEqual(Some("customerId"))
  })

  testSync("the key is exposed on the module", () => {
    expect((OrderId.key, CustomerId.key))->toEqual(("orderId", "customerId"))
  })
})
