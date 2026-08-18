/**
A location on the earth: a latitude and a longitude, as one value.

## Why the pair is the value, not two fields beside each other

Before this type a coordinate reached a map by three statements agreeing with
each other: a read model flattened the point into `lat` and `lng` scalar fields,
the UI guessed the pair back from those names, and a map was offered only when
both guesses hit. Three things go wrong and all three are silent. Two points in
one row mispair across each other — the two guesses are independent, so
`pickupLat`/`pickupLng` beside `dropoffLat`/`dropoffLng` can pin a marker at one
point's latitude and the other's longitude, a location in the sea drawn without
an error. A pair named anything else — `y`/`x`, `northing`/`easting` — is
invisible. And nothing checks the numbers: `lat: 181.0` is a `float` and passes
every boundary in the system.

Making the two numbers one value removes the pairing question, and gives the
checks somewhere to live.

## Latitude first here, longitude first only in GeoJSON

This is the ordering trap the whole geo domain is famous for. GeoJSON (RFC 7946)
encodes a point as `{"type":"Point","coordinates":[lng, lat]}` — **longitude
first** — while every UI API and every human writes latitude first. A swapped
pair is not an error anywhere: it is a plausible-looking marker in the wrong
hemisphere.

So the shape here keeps *names*, where an order cannot be got wrong, and the
positional order exists in exactly one place: `toGeoJson`/`fromGeoJson` below.
Any consumer that re-derives that conversion is re-deciding something already
decided, and will eventually disagree with it.

## The invariants are checked at decode

Latitude runs −90…90 and longitude −180…180. Each range is a property of *one*
field, so — unlike `DateRange`, whose ordering rule relates two fields and cannot
be refined while sury 11-alpha miscompiles a record-level refinement — these sit
on the field schemas and the boundary rejects a bad coordinate on the way in.
This type has the same decode-time guarantee `Money` has, and more than
`DateRange`; a reader arriving from `DateRange` would assume the weaker one.

The two ranges are deliberately not one "coordinate" check: latitude saturates
at the poles and longitude wraps at the antimeridian, and ±90 versus ±180 is the
whole of the difference between them.

## How a field declares it

The field's declared type *is* `GeoPoint.t`, and sury-ppx resolves it to this
module's `schema`:

```rescript
@schema type state = {
  customerId: string,
  location: option<Reventless.GeoPoint.t>,
}
```

which serializes as `{"lat": 48.2082, "lng": 16.3738}`.

**Replacing a hand-rolled `{lat: float, lng: float}` record with this type is
free** — the wire shape is identical, so every stored event decodes unchanged and
no upcaster is owed. That is the cheapest of the three adoption paths a semantic
type has, and it is the one most existing coordinate fields are on. It costs a
log something only if it *collapses* two flattened scalar fields back into one,
which rewrites that shape.
*/

/**
Validate a latitude, saying why when it is out of range.

The single statement of the rule; `latSchema` is derived from it, so there is
nowhere for a second grammar to drift.
*/
let validateLat = (raw: float): result<float, string> =>
  if !Float.isFinite(raw) {
    Error(`a latitude must be a finite number of degrees, got ${Float.toString(raw)}`)
  } else if raw < -90.0 || raw > 90.0 {
    Error(
      `a latitude runs from -90 to 90 degrees, got ${Float.toString(raw)}. ` ++
      `A value beyond ±90 is usually a longitude in the latitude's place.`,
    )
  } else {
    Ok(raw)
  }

/** Validate a longitude, saying why when it is out of range. The other half of
    the pair, separate because ±180 is what makes it a longitude. */
let validateLng = (raw: float): result<float, string> =>
  if !Float.isFinite(raw) {
    Error(`a longitude must be a finite number of degrees, got ${Float.toString(raw)}`)
  } else if raw < -180.0 || raw > 180.0 {
    Error(`a longitude runs from -180 to 180 degrees, got ${Float.toString(raw)}`)
  } else {
    Ok(raw)
  }

/** The latitude's own schema. The check sits on the field rather than on the
    pair because the range is a property of the one number — and because sury
    11-alpha miscompiles a refinement wrapping a *record* schema. Refining the
    field is both the honest placement and the one that works. */
let latSchema: S.t<float> =
  S.float->S.refine(
    raw =>
      switch validateLat(raw) {
      | Ok(_) => true
      | Error(_) => false
      },
    ~error="expected a latitude in -90…90",
  )

/** The longitude's own schema, for the same reason. */
let lngSchema: S.t<float> =
  S.float->S.refine(
    raw =>
      switch validateLng(raw) {
      | Ok(_) => true
      | Error(_) => false
      },
    ~error="expected a longitude in -180…180",
  )

@schema
type t = {
  /** Degrees north of the equator, −90…90. Negative is south. */
  lat: @s.matches(latSchema) float,
  /** Degrees east of the prime meridian, −180…180. Negative is west. */
  lng: @s.matches(lngSchema) float,
}

/** The sury schema for a geo-point field, carrying the `geoPoint` semantic.

    Shadows the schema sury-ppx derived from the type above: the derived one is
    the shape, and this adds the marker the shape cannot carry. */
let schema: S.t<t> = schema->Semantic.mark(~id=Semantic.Id.geoPoint)

/** Build a validated point. Both coordinates are checked, and the message names
    which one is wrong — the common mistake is a swapped pair, where the
    longitude lands in the latitude and is the value that fails. */
let make = (~lat: float, ~lng: float): result<t, string> =>
  switch (validateLat(lat), validateLng(lng)) {
  | (Error(why), _) | (Ok(_), Error(why)) => Error(why)
  | (Ok(lat), Ok(lng)) => Ok({lat, lng})
  }

/**
The point as text: latitude, then longitude — `"48.2082, 16.3738"`.

Latitude first, the order a human reads and the opposite of GeoJSON's. Locale
independent, matching the rest of the framework's formatters: the same value
reads the same in every log line and every test.
*/
let format = (p: t): string => `${Float.toString(p.lat)}, ${Float.toString(p.lng)}`

/** The mean radius of the earth in metres (IUGG R₁). One constant, so a distance
    computed here and a distance computed elsewhere cannot disagree by their
    choice of sphere. */
let earthRadiusMetres = 6371008.8

let toRadians = (degrees: float): float => degrees *. Math.Constants.pi /. 180.0

/**
The great-circle distance between two points, in metres.

Haversine on a spherical earth, which is accurate to roughly 0.5% — right for
radii, catchments and sorting by nearness, and wrong for surveying. Anything
needing geodesic accuracy needs an ellipsoid and a library that models one.

It lives here rather than at each consumer because "how far" is the operation
every geo consumer eventually wants, and writing it per consumer is where the
degrees-versus-radians and earth-radius mistakes live — mistakes that produce a
plausible number rather than a failure.
*/
let distanceTo = (a: t, b: t): float => {
  let lat1 = toRadians(a.lat)
  let lat2 = toRadians(b.lat)
  let dLat = toRadians(b.lat -. a.lat)
  let dLng = toRadians(b.lng -. a.lng)
  let h =
    Math.sin(dLat /. 2.0) *. Math.sin(dLat /. 2.0) +.
      Math.cos(lat1) *. Math.cos(lat2) *. Math.sin(dLng /. 2.0) *. Math.sin(dLng /. 2.0)
  2.0 *. Math.asin(Math.sqrt(Math.min(1.0, h))) *. earthRadiusMetres
}

/**
The point as a GeoJSON `Point` geometry — `{"type":"Point","coordinates":[lng, lat]}`.

**This is the one place the positional order is written.** Longitude first, per
RFC 7946. Every map library, spatial database and geocoding API on that side of
the boundary expects it; every human on this side does not, which is why the
stored shape keeps names and only this function turns them into an array.
*/
let toGeoJson = (p: t): JSON.t =>
  JSON.Encode.object(
    Dict.fromArray([
      ("type", JSON.Encode.string("Point")),
      ("coordinates", JSON.Encode.array([JSON.Encode.float(p.lng), JSON.Encode.float(p.lat)])),
    ]),
  )

/**
Read a GeoJSON `Point` geometry back, validating both coordinates.

The inverse of `toGeoJson`, and the only other place the positional order is
read. Returns `Error` for a geometry that is not a point, for coordinates that
are not two numbers, and — via `make` — for numbers out of range, which is what
catches a `[lat, lng]` array produced by something that got the order wrong,
whenever the latitude exceeds ±90.
*/
let fromGeoJson = (json: JSON.t): result<t, string> =>
  switch json->JSON.Decode.object {
  | None => Error("a GeoJSON point is an object")
  | Some(o) =>
    switch o->Dict.get("type")->Option.flatMap(JSON.Decode.string) {
    | Some("Point") =>
      switch o->Dict.get("coordinates")->Option.flatMap(JSON.Decode.array) {
      | Some(coords) =>
        switch (
          coords->Array.get(0)->Option.flatMap(JSON.Decode.float),
          coords->Array.get(1)->Option.flatMap(JSON.Decode.float),
        ) {
        // [lng, lat] — the RFC's order, not this module's.
        | (Some(lng), Some(lat)) => make(~lat, ~lng)
        | _ => Error("a GeoJSON point's coordinates are two numbers, [lng, lat]")
        }
      | None => Error("a GeoJSON point has a coordinates array")
      }
    | Some(other) => Error(`expected a GeoJSON Point, got ${other}`)
    | None => Error("a GeoJSON geometry has a type")
    }
  }
