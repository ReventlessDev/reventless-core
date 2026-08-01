open JestGlobals

// `GeoPoint` is the composite with the *strongest* decode guarantee: both its
// invariants are per-field ranges, so unlike `DateRange`'s record-level ordering
// rule they refine the field schemas and the boundary rejects a bad coordinate.
// The load-bearing cases below are therefore the ones that hold that in place —
// decode refuses an out-of-range coordinate on both fields and both signs — plus
// the GeoJSON codec's array *order*, which is the one thing in this module a
// round-trip test cannot catch on its own.
describe("GeoPoint:", () => {
  let p = (lat, lng): GeoPoint.t => {lat, lng}

  // Vienna (Stephansdom) and Bratislava (hrad) — ~55 km apart, and the pair the
  // distance case is calibrated against.
  let vienna = p(48.2082, 16.3738)
  let bratislava = p(48.1420, 17.1000)

  describe("validateLat is the single statement of the latitude range:", () => {
    testSync("the equator is accepted", () => expect(GeoPoint.validateLat(0.0)->Result.isOk)->toBe(true))
    testSync("the north pole is accepted", () =>
      expect(GeoPoint.validateLat(90.0)->Result.isOk)->toBe(true)
    )
    testSync("the south pole is accepted", () =>
      expect(GeoPoint.validateLat(-90.0)->Result.isOk)->toBe(true)
    )
    testSync("beyond the pole is refused", () =>
      expect(GeoPoint.validateLat(90.1)->Result.isOk)->toBe(false)
    )
    // The failure this rejection exists for: a longitude written into the
    // latitude's place. Anything past ±90 can only be that.
    testSync("a longitude in the latitude's place is refused", () =>
      expect(GeoPoint.validateLat(151.2093)->Result.isOk)->toBe(false)
    )
    testSync("the refusal quotes the offending number", () =>
      expect(
        switch GeoPoint.validateLat(181.0) {
        | Error(why) => why->String.includes("181")
        | Ok(_) => false
        },
      )->toBe(true)
    )
    testSync("a non-finite latitude is refused", () =>
      expect(GeoPoint.validateLat(Float.Constants.nan)->Result.isOk)->toBe(false)
    )
  })

  // Separate from the latitude's on purpose: ±180 versus ±90 is the whole of the
  // difference between the two coordinates, so a value legal here is illegal
  // there.
  describe("validateLng runs to ±180, not ±90:", () => {
    testSync("the antimeridian is accepted", () =>
      expect(GeoPoint.validateLng(180.0)->Result.isOk)->toBe(true)
    )
    testSync("its western twin is accepted", () =>
      expect(GeoPoint.validateLng(-180.0)->Result.isOk)->toBe(true)
    )
    testSync("a longitude past ±90 is fine — this is what makes it a longitude", () =>
      expect(GeoPoint.validateLng(151.2093)->Result.isOk)->toBe(true)
    )
    testSync("beyond the antimeridian is refused", () =>
      expect(GeoPoint.validateLng(180.1)->Result.isOk)->toBe(false)
    )
  })

  describe("make checks both coordinates:", () => {
    testSync("a valid pair is built", () =>
      expect(GeoPoint.make(~lat=48.2082, ~lng=16.3738))->toEqual(Ok(vienna))
    )
    testSync("a bad latitude is refused", () =>
      expect(GeoPoint.make(~lat=91.0, ~lng=0.0)->Result.isOk)->toBe(false)
    )
    testSync("a bad longitude is refused", () =>
      expect(GeoPoint.make(~lat=0.0, ~lng=181.0)->Result.isOk)->toBe(false)
    )
  })

  describe("format is latitude first, locale-independent:", () =>
    testSync("lat, then lng", () => expect(GeoPoint.format(vienna))->toBe("48.2082, 16.3738"))
  )

  describe("distanceTo is the great-circle distance in metres:", () => {
    // ~55 km. The tolerance admits the spherical approximation (~0.5%) and would
    // still fail a degrees/radians slip, which is wrong by a factor of ~57.
    testSync("Vienna to Bratislava is about 55 km", () => {
      let d = GeoPoint.distanceTo(vienna, bratislava)
      expect(d > 53000.0 && d < 57000.0)->toBe(true)
    })
    testSync("a point is zero metres from itself", () =>
      expect(GeoPoint.distanceTo(vienna, vienna))->toBe(0.0)
    )
    testSync("distance is symmetric", () =>
      expect(GeoPoint.distanceTo(vienna, bratislava))->toBe(
        GeoPoint.distanceTo(bratislava, vienna),
      )
    )
  })

  describe("the GeoJSON codec is the one place the order is positional:", () => {
    let geometry = GeoPoint.toGeoJson(vienna)

    testSync("it is a Point geometry", () =>
      expect(
        geometry
        ->JSON.Decode.object
        ->Option.flatMap(o => o->Dict.get("type"))
        ->Option.flatMap(JSON.Decode.string),
      )->toEqual(Some("Point"))
    )

    // The assertion that matters. A round-trip test passes with both ends
    // swapped consistently, which is exactly the bug this module exists to
    // prevent — so the array is read directly: longitude first, per RFC 7946.
    testSync("coordinates are [lng, lat] — longitude first", () =>
      expect(
        geometry
        ->JSON.Decode.object
        ->Option.flatMap(o => o->Dict.get("coordinates"))
        ->Option.flatMap(JSON.Decode.array)
        ->Option.map(a => a->Array.filterMap(JSON.Decode.float)),
      )->toEqual(Some([16.3738, 48.2082]))
    )

    testSync("and it round-trips", () => expect(GeoPoint.fromGeoJson(geometry))->toEqual(Ok(vienna)))

    // A `[lat, lng]` array from something that got the order wrong is caught
    // whenever the latitude exceeds ±90 — the range check doing double duty.
    testSync("a swapped array is refused when the latitude cannot be one", () =>
      expect(
        GeoPoint.fromGeoJson(
          JSON.Encode.object(
            Dict.fromArray([
              ("type", JSON.Encode.string("Point")),
              (
                "coordinates",
                JSON.Encode.array([JSON.Encode.float(48.2082), JSON.Encode.float(151.2093)]),
              ),
            ]),
          ),
        )->Result.isOk,
      )->toBe(false)
    )

    testSync("a non-point geometry is refused", () =>
      expect(
        GeoPoint.fromGeoJson(
          JSON.Encode.object(Dict.fromArray([("type", JSON.Encode.string("Polygon"))])),
        )->Result.isOk,
      )->toBe(false)
    )
    testSync("a geometry without coordinates is refused", () =>
      expect(
        GeoPoint.fromGeoJson(
          JSON.Encode.object(Dict.fromArray([("type", JSON.Encode.string("Point"))])),
        )->Result.isOk,
      )->toBe(false)
    )
  })

  describe("the schema:", () => {
    let point = (lat, lng) =>
      JSON.Encode.object(
        Dict.fromArray([("lat", JSON.Encode.float(lat)), ("lng", JSON.Encode.float(lng))]),
      )

    let parses = (raw: JSON.t) =>
      switch raw->S.parseOrThrow(GeoPoint.schema) {
      | _ => true
      | exception _ => false
      }

    testSync("carries the geoPoint id", () =>
      expect(GeoPoint.schema->S.castToUnknown->Semantic.has(~id="geoPoint"))->toBe(true)
    )

    // The vocabulary id is a string contract with a consumer in another repo
    // that nothing type-checks across the boundary — compared to a literal on
    // purpose, exactly as `money` and `dateRange` are.
    testSync("and the id is the wire string", () => expect(Semantic.Id.geoPoint)->toBe("geoPoint"))

    testSync("accepts a valid point", () => expect(parses(point(48.2082, 16.3738)))->toBe(true))

    // The parity claim this type turns on, stated as tests: unlike `DateRange`,
    // decode enforces the invariants, because each is a property of one field.
    testSync("decode REFUSES an out-of-range latitude", () =>
      expect(parses(point(91.0, 0.0)))->toBe(false)
    )
    testSync("decode REFUSES a negative out-of-range latitude", () =>
      expect(parses(point(-91.0, 0.0)))->toBe(false)
    )
    testSync("decode REFUSES an out-of-range longitude", () =>
      expect(parses(point(0.0, 181.0)))->toBe(false)
    )
    testSync("decode REFUSES a negative out-of-range longitude", () =>
      expect(parses(point(0.0, -181.0)))->toBe(false)
    )

    testSync("serializes as {lat, lng}", () =>
      expect(vienna->S.reverseConvertToJsonOrThrow(GeoPoint.schema))->toEqual(
        point(48.2082, 16.3738),
      )
    )

    // The shape-preserving claim, asserted rather than described: JSON written
    // by the hand-rolled `{lat, lng}` record this type replaces parses against
    // it unchanged, which is why retyping such a field owes the log no upcaster.
    testSync("JSON from a hand-rolled {lat, lng} record parses unchanged", () => {
      let legacy: {"lat": float, "lng": float} = {"lat": 48.2082, "lng": 16.3738}
      expect(
        legacy->Obj.magic->S.parseOrThrow(GeoPoint.schema),
      )->toEqual(vienna)
    })
  })
})
