open JestGlobals
open TaggedUnionFixtures

// Two markers ride on one schema; a lost one emits the field as `String` with
// nothing reporting it. Also pins a negative: the name does NOT come from
// `semanticCompositeNames`, so an entry there would be inert.

module GeoCustomersSpec = {
  module Id = Reventless.Id.StringPure
  let name = "SemanticGeolocationCustomers"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type state = {customerId: string, geolocation: Reventless.Geolocation.t}

  let config = Reventless.ReadModel.config()
  let subIdConfig = None
}

let fragment = GraphQL_FragmentGenerator.generate(
  ~mutationEntries=[],
  ~queryEntries=[
    queryEntryFor(
      ~returnTypeName="SemanticGeoCustomer",
      ~specName=GeoCustomersSpec.name,
      GeoCustomersSpec.stateSchema,
    ),
  ],
)

let types = GraphQL_Stitcher.decode(fragment).types
let typeDefFor = needle => types->Array.find(t => t->String.includes(needle))->Option.getOr("")

describe("the Geolocation semantic reaches the IR as a named union", () => {
  let field = switch SchemaType.fromSuryObject(
    ~typeName="SemanticGeoCustomer",
    GeoCustomersSpec.stateSchema->S.castToUnknown,
  ) {
  | Some(fields) => fields->Dict.get("geolocation")
  | None => None
  }

  // If the walk stopped at the marker, the field would classify as `Unknown`.
  testSync("the semantic marker does not swallow the union", () => {
    switch field {
    | Some(Semantic({id}, TaggedUnion(name, arms))) =>
      expect((id, name, arms->Array.length))->toEqual((
        Reventless.Semantic.Id.geolocation,
        "Geolocation",
        3,
      ))
    | _ => expect("geolocation")->toBe("Semantic(geolocation, TaggedUnion(Geolocation, 3 arms))")
    }
  })

  // A path-composed name would carry the spec's name; this one must not.
  testSync("the union is named from the schema, not from where it was found", () => {
    switch field {
    | Some(Semantic(_, TaggedUnion(name, _))) =>
      expect(name->String.includes("Customer"))->toBe(false)
      expect(name)->toBe("Geolocation")
    | _ => expect("geolocation")->toBe("a named TaggedUnion")
    }
  })

  // An entry there would leave this passing — it decides nothing.
  testSync("semanticCompositeNames does not name this union", () => {
    expect(SchemaType.canonicalName(Reventless.Semantic.Id.geolocation))->toEqual(None)
  })
})

// The breaking half, asserted rather than assumed.
describe("a row in the pre-union shape does not decode", () => {
  let oldShapedRow = JSON.parseOrThrow(`{
    "customerId": "c1",
    "location": {"lat": 48.2082, "lng": 16.3738},
    "locationStatus": "Located",
    "locationNote": null
  }`)

  testSync("the three-field shape is refused against the union schema", () => {
    let decodes = switch oldShapedRow->S.parseOrThrow(~to=GeoCustomersSpec.stateSchema) {
    | _ => true
    | exception _ => false
    }
    expect(decodes)->toBe(false)
  })
})

describe("the Geolocation semantic emits its three member types", () => {
  testSync("the union declaration lists all three members", () => {
    let union = typeDefFor("union Geolocation")
    expect(union->String.includes("GeolocationPending"))->toBe(true)
    expect(union->String.includes("GeolocationLocated"))->toBe(true)
    expect(union->String.includes("GeolocationUnresolvable"))->toBe(true)
  })

  // Also says a composite nested in an arm keeps its own canonical name.
  testSync("the located member carries a GeoPoint", () => {
    expect(typeDefFor("type GeolocationLocated")->String.includes("GeoPoint"))->toBe(true)
  })

  testSync("the field is typed as the union", () => {
    expect(typeDefFor("type SemanticGeoCustomer")->String.includes("geolocation: Geolocation"))->toBe(
      true,
    )
  })
})
