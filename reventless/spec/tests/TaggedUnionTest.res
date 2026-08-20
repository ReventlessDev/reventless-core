open JestGlobals

// The marker, the classification rules, and the one sury behaviour the marker
// depends on.

@schema
type geolocation =
  | Pending({requestedFor: string})
  | Located({lat: float, lng: float})
  | Unresolvable({reason: string})

let namedSchema = TaggedUnion.named(~name="Geolocation", geolocationSchema)

@schema
type bareArms =
  | Pending
  | Located

@schema
type positional =
  | Approved(string)
  | Rejected({reason: string})

let unknown = (schema: S.t<'a>) => schema->S.castToUnknown

describe("TaggedUnion.getName", () => {
  testSync("reads the name off the union", () => {
    expect(TaggedUnion.getName(namedSchema->unknown))->toEqual(Some("Geolocation"))
  })

  // The one that would fail silently if sury changed: `option<t>` does NOT keep
  // the union as a nested schema — it flattens the arms and the `undefined` into
  // one `anyOf`, so there is nothing inside left to consult. What makes an
  // optional union field work at all is that the metadata survives onto the
  // wrapper. If it stopped, every optional union field would quietly become a
  // `String` in the SDL with no compile error anywhere.
  testSync("survives the option wrapper", () => {
    expect(TaggedUnion.getName(S.option(namedSchema)->unknown))->toEqual(Some("Geolocation"))
  })

  testSync("an unmarked union has no name", () => {
    expect(TaggedUnion.getName(geolocationSchema->unknown))->toEqual(None)
  })
})

describe("TaggedUnion.armsOf", () => {
  let tags = schema =>
    TaggedUnion.armsOf(schema->unknown)->Option.map(arms => arms->Array.map(a => a.tag))

  testSync("names every arm of a payload union", () => {
    expect(tags(geolocationSchema))->toEqual(Some(["Pending", "Located", "Unresolvable"]))
  })

  testSync("sees through the option wrapper's flattened anyOf", () => {
    expect(tags(S.option(geolocationSchema)))->toEqual(
      Some(["Pending", "Located", "Unresolvable"]),
    )
  })

  // An enum is a different type with a different emission — not a union of
  // object types, and not this module's business.
  testSync("declines an enum", () => {
    expect(tags(bareArmsSchema))->toEqual(None)
  })

  // `_0` is the compiler's name, and it would be published as an SDL field name
  // and as a stored key. The ppx refuses the declaration; this refuses the union
  // wherever the ppx cannot see it.
  testSync("declines a positional payload", () => {
    expect(tags(positionalSchema))->toEqual(None)
  })

  testSync("declines a plain record", () => {
    expect(tags(S.schema(s => {"lat": s.matches(S.float)})))->toEqual(None)
  })
})

describe("TaggedUnion.stampInto", () => {
  let stamped = (~schema, json) => {
    TaggedUnion.stampInto(~schema=schema->unknown, json)
    json->JSON.stringify
  }

  let stateSchema = S.schema(s => {"geolocation": s.matches(namedSchema)})

  testSync("writes the member type beside the TAG", () => {
    let json = JSON.parseOrThrow(`{"geolocation":{"TAG":"Located","lat":1,"lng":2}}`)
    expect(stamped(~schema=stateSchema, json))->toBe(
      `{"geolocation":{"TAG":"Located","lat":1,"lng":2,"__typename":"GeolocationLocated"}}`,
    )
  })

  // Releasable ahead of any adopter: a row with no union field comes out of the
  // walk exactly as it went in.
  testSync("leaves a row with no union field untouched", () => {
    let schema = S.schema(s => {"name": s.matches(S.string)})
    let json = JSON.parseOrThrow(`{"name":"Widget"}`)
    expect(stamped(~schema, json))->toBe(`{"name":"Widget"}`)
  })

  testSync("leaves an unnamed union untouched", () => {
    let schema = S.schema(s => {"geolocation": s.matches(geolocationSchema)})
    let json = JSON.parseOrThrow(`{"geolocation":{"TAG":"Located","lat":1,"lng":2}}`)
    expect(stamped(~schema, json))->toBe(`{"geolocation":{"TAG":"Located","lat":1,"lng":2}}`)
  })
})
