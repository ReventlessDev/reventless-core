open JestGlobals

// A field holding a quantity, or money per a quantity's unit, says which in its
// JSON schema: the semantic, and the quantity and unit in their own key.

let getProperty = (schema: JSON.t, key: string): option<JSON.t> =>
  schema->JSON.Decode.object->Option.flatMap(o => o->Dict.get(key))

let fieldOf = (json, name) =>
  getProperty(json, "properties")->Option.flatMap(p => getProperty(p, name))

let unitTarget = (~quantity, ~unit) => Some(
  JSON.Encode.object(
    Dict.fromArray([
      ("quantity", JSON.Encode.string(quantity)),
      ("unit", JSON.Encode.string(unit)),
    ]),
  ),
)

let schema = S.schema(s =>
  {
    "sessionId": s.matches(S.string),
    "delivered": s.matches(Reventless.Energy.kilowattHour),
    "price": s.matches(Reventless.PricePer.unit(Reventless.Energy.kilowattHour)),
    "maxPower": s.matches(S.option(Reventless.Power.kilowatt)),
  }
)->S.castToUnknown

let json = SuryToJsonSchema.deriveObjectSchema(schema)

describe("a quantity in a view's JSON schema", () => {
  testSync("a quantity field carries the semantic and its unit", () => {
    let field = fieldOf(json, "delivered")
    expect(field->Option.flatMap(getProperty(_, "x-reventless-semantic")))->toEqual(
      Some(JSON.Encode.string("quantity")),
    )
    expect(field->Option.flatMap(getProperty(_, "x-reventless-semantic-unit")))->toEqual(
      unitTarget(~quantity="energy", ~unit="kWh"),
    )
    // Still a number: typing a field changes nothing stored.
    expect(field->Option.flatMap(getProperty(_, "type")))->toEqual(
      Some(JSON.Encode.string("number")),
    )
  })

  testSync("a price per unit carries its semantic and the unit it is per", () => {
    let field = fieldOf(json, "price")
    expect(field->Option.flatMap(getProperty(_, "x-reventless-semantic")))->toEqual(
      Some(JSON.Encode.string("pricePerUnit")),
    )
    expect(field->Option.flatMap(getProperty(_, "x-reventless-semantic-unit")))->toEqual(
      unitTarget(~quantity="energy", ~unit="kWh"),
    )
  })

  testSync("an optional quantity keeps its unit", () =>
    expect(
      fieldOf(json, "maxPower")->Option.flatMap(getProperty(_, "x-reventless-semantic-unit")),
    )->toEqual(unitTarget(~quantity="power", ~unit="kW"))
  )

  testSync("a field with no quantity has no unit key", () =>
    expect(
      fieldOf(json, "sessionId")->Option.flatMap(getProperty(_, "x-reventless-semantic-unit")),
    )->toEqual(None)
  )
})
