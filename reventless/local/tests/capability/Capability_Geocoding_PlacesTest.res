open JestGlobals

// The local geocoder over a places file: a listed place resolves to its point, an
// address resolves by the place it ends with, and anything else stays queued.

let yaml = `
- place: Bruges
  point: { lat: 51.2093, lng: 3.2247 }
- place: Delft
  point: { lat: 52.0116, lng: 4.3571 }
`

let places = switch Capability_Geocoding_Places.parseString(yaml) {
| Ok(places) => places
| Error(why) => JsError.throwWithMessage(why)
}

let search = Capability_Geocoding_Places.search(places)

let pointOf = async text =>
  switch await search(~text) {
  | Ok([{point}]) => Some(point)
  | _ => None
  }

describe("Capability_Geocoding_Places.search", () => {
  test("a listed place resolves to its point", async () => {
    expect(await pointOf("Bruges"))->toEqual(Some({Reventless.GeoPoint.lat: 51.2093, lng: 3.2247}))
  })

  test("an address resolves by the place it ends with, whatever its case and spacing", async () => {
    expect(await pointOf("12 Elm Row,  delft "))->toEqual(
      Some({Reventless.GeoPoint.lat: 52.0116, lng: 4.3571}),
    )
  })

  test("the answer is confident, so the trait locates the address", async () => {
    let answer = await search(~text="12 Elm Row, Delft")
    expect(
      switch Reventless.Geolocation.ofSearch(~requestedFor="12 Elm Row, Delft", answer) {
      | Some(Located(_)) => true
      | _ => false
      },
    )->toBe(true)
  })

  test("an address naming no listed place is unavailable, not a made-up point", async () => {
    expect(
      switch await search(~text="3 Canal Street, Utrecht") {
      | Error(Unavailable(why)) => why->String.includes("places.yaml")
      | _ => false
      },
    )->toBe(true)
  })

  test("a place inside an address but not at its end does not match", async () => {
    expect(await pointOf("Bruges Road, Utrecht"))->toEqual(None)
  })
})

describe("Capability_Geocoding_Places.load", () => {
  testSync("no file is no geocoder", () => {
    let dir = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "reventless-places-"]))
    expect(Capability_Geocoding_Places.load(~path=NodePath.join([dir, "places.yaml"])))->toEqual(
      None,
    )
  })

  testSync("a point out of range refuses the file", () => {
    expect(
      Capability_Geocoding_Places.parseString(`- place: Nowhere\n  point: { lat: 3.2, lng: 251.2 }`)->Result.isError,
    )->toBe(true)
  })
})
