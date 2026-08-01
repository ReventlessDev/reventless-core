# Plan: `GeoPoint` and the map capability

**Date:** 2026-08-01
**Status:** Steps 1–3 implemented and verified (2026-08-01), unreleased. Step 4 is the reader half
and is planned and implemented in reventless-ui, per the split `DateRange` established.

**Landed (reventless-core):**
- **Steps 1–2** — `reventless/spec/src/semantic/GeoPoint.res`: the `@schema {lat, lng}` record with
  each coordinate refined by its own range schema, a `schema` shadow carrying `Semantic.Id.geoPoint`,
  and the value-object ops `validateLat` / `validateLng` / `make` / `format` / `distanceTo` /
  `toGeoJson` / `fromGeoJson`. The `[lng, lat]` order lives only in the codec.
- **Step 3** — the hybrid example: `Customer.location` retyped from its local `{lat, lng}` record to
  `Reventless.GeoPoint.t` (shape-preserving, the local type deleted), and `Customers` collapsed from
  `lat: float, lng: float` to `location: option<Reventless.GeoPoint.t>`, projection and GWT fixtures
  with it. The seed data set needed no change at all — its `SetLocation({location: {lat, lng}})`
  record literal infers straight into the new type, which is the shape-preserving claim showing up
  as an absence of work.
- **Verification** — `GeoPointTest` (33), the `SuryToJsonSchemaTest` emission block (4), full build
  including every example platform root, and the whole suite green at **288 suites / 2577 tests**
  with no `.res.mjs` deletions. **Not yet done: the live local-platform round trip** (the last
  verification bullet below) — the map renders from the declaration only once the UI half is pinned
  beside this, so it is worth running once, against both.
**Repos:** `reventless-core` **and** `reventless-ui`. Like `Money` and `DateRange`, and unlike the
branded scalars, this one needs UI work — but less of it than either, for a reason worth stating up
front: **the renderer and the form input already exist and already read `{lat, lng}`.** What is
missing is the declaration, the invariants, and the role the declaration should feed.
**Analysis:** the semantic table's geo-point row and §5.6 / §12 — in the repo that owns the cross-repo
semantic-type analysis. That analysis picked `GeoPoint` as *the* canonical case ("one type replaces
two fields + a heuristic + the annotation") and then handed the first-composite slot to `StorageRef`;
this is that case being cashed in.
**Builds on:** [done/semantic-money-and-currency.md](./done/semantic-money-and-currency.md) — the
composite template and its **D2** (a record-level refinement miscompiles) — and
[semantic-date-range.md](./semantic-date-range.md), whose adoption table this plan extends with a
third row.

## What this replaces: two fields, a heuristic, and an annotation

A coordinate reaches a map today by three separate statements agreeing with each other:

1. the read model flattens the point into **two scalar fields**, `lat: float` and `lng: float`;
2. the UI **guesses the pair back** — among numeric fields, the first named `lat`/`latitude` and the
   first named `lng`/`lon`/`long`/`longitude`, independently;
3. and the map mode is offered only when both guesses hit.

The hybrid example is the proof, and it contains both ends of the problem at once. `Customer` carries
a hand-rolled `type location = {lat: float, lng: float}` on its `SetLocation` command and `LocationSet`
event — a value object in everything but name, with no invariants and no marker. `Customers` then
*unflattens it into the pair*, and its own comment says why: "`lat`/`lng` are a numeric coordinate
pair, so the generated read-model view offers a map display." The projection writes
`{...state, lat: location.lat, lng: location.lng}` — one value taken apart so that a name heuristic
can put it back together.

Three failure modes follow, and they are the geo spelling of `DateRange`'s three:

- **Two points in one row mispair across each other.** The two `find`s are independent, so a row with
  `pickupLat`/`pickupLng` beside `dropoffLat`/`dropoffLng` can pin a marker at one point's latitude and
  the other's longitude — a location in the sea, drawn without an error.
- **A pair not named `lat`/`lng` is invisible.** `y`/`x`, `northing`/`easting`, `coordLat`/`coordLon`
  are all coordinates by meaning and none by prefix; the map mode simply is not offered.
- **Nothing checks the numbers.** `lat: 181.0` is a `float` and passes every boundary in the system.
  A point out of range does not fail: it renders somewhere wrong, or MapLibre clamps it silently.

There is also a fourth, specific to geo and worse than the other three: **`[lng, lat]` versus
`[lat, lng]`**. GeoJSON is longitude-first; almost every UI API and every human is latitude-first.
`MapData.featureCollection` gets it right today, and it gets it right *once* — every future consumer
that crosses the same boundary re-decides it, and a swapped pair is a plausible-looking marker in the
wrong hemisphere.

## The shape

```rescript
@schema
type t = {
  lat: @s.matches(latSchema) float,   // −90 … 90
  lng: @s.matches(lngSchema) float,   // −180 … 180
}
```

which serializes as `{"lat": 48.2082, "lng": 16.3738}` — **the shape the example already stores and
the shape both UI paths already read.** That is not a coincidence to be grateful for; it is the
reason this type is cheap, and it decides the adoption category below.

### D1. Named `{lat, lng}`, not a GeoJSON position

The interchange format for geo is GeoJSON, whose point is `{"type":"Point","coordinates":[lng,lat]}`
— a **positional** pair, longitude first. Making that the stored shape would put the framework's
worst-known ordering trap into every field's wire format and every ReScript pattern match.

So the type keeps names, and the codec is a *function on it* (D3). The analysis says the same thing
and says why: a named shape is what stops "the ocean bug", and the codec is what stops a second,
divergent conversion appearing at each boundary.

### D2. Both invariants are per-field, so unlike `DateRange` they *are* enforced at decode

`Money` refines `amount` because wholeness is a property of that one field; `DateRange` cannot refine
anything, because `start <= end` relates two fields and sury 11.0.0-alpha.4 miscompiles a refinement
wrapping a record schema.

Latitude's range and longitude's range are each properties of **one** field. So they sit on the field
schemas exactly as `Money.amountSchema` does, they cost nothing to the sury pin, and **the boundary
rejects an out-of-range coordinate**. This type has full decode-time parity with `Money` and more than
`DateRange` — worth saying explicitly, because a reader arriving from `DateRange`'s "the schema does
not enforce it" would assume the weaker guarantee.

The asymmetric ranges are not decoration: latitude saturates at the poles and longitude wraps at the
antimeridian, so ±90/±180 is the whole of the difference between them, and a single "coordinate"
refinement would be wrong for one of the two.

### D3. The GeoJSON codec ships *with* the type

`toGeoJson` / `fromGeoJson` on the module, not at each consumer. This is the decision the plan turns
on, and the argument is the ordering trap: a codec written once, beside the type, in the module whose
doc explains the order, is one place to get it right. `MapData.featureCollection` in the UI is
currently that place, and it is one of several boundaries — an external geocoding call, a PostGIS
write and a map click each cross the same line.

The counter-argument is scope: a spec package that knows about RFC 7946 is a spec package with an
interchange format in it. That is answered by keeping it to **`Point` only** and to a plain
`Js.Json.t`, which is a two-way function over a shape, not an adoption of GeoJSON as the wire format.
Geometries beyond the point are out of scope (below), and if `GeoArea`/`GeoPath` ever land, this is
the module their codec sits beside.

### D4. `distanceTo`, in metres, haversine

Proximity is the one operation every geo consumer eventually wants — "venues near here", a delivery
radius, "is this within the zone". Written per consumer, it is where the degree/radian and
earth-radius mistakes live, and they are mistakes that produce a *plausible* number.

Haversine on a spherical earth (R = 6 371 008.8 m, the IUGG mean radius) is accurate to about 0.5%,
which is right for radii and sorting and wrong for surveying. The doc says so; anything needing
geodesic accuracy needs an ellipsoid and does not belong in a spec package.

## What this costs a deployment: a third adoption category, and it is the cheap one

`DateRange`'s plan split adoption into *breaking* (`Money`, which rewrote `price: float` into an
object) and *additive* (a new `option<DateRange.t>` field, absent decodes to `None`). `GeoPoint`
introduces a third, and the hybrid example needs both of the ones that apply:

| Category | What it is | What the log owes |
|---|---|---|
| **Breaking retype** | a scalar becomes an object — `Money` on `price` | an upcaster + a projection rebuild |
| **Additive** | a new `option<T>` field — `DateRange` on `deliveryWindow` | nothing |
| **Shape-preserving retype** ← this plan | a hand-rolled record becomes the framework type at **the same wire shape** | **nothing** |

`Customer.location` is already `{lat: float, lng: float}`. Retyping it to `GeoPoint.t` changes the
declared type, adds the marker and adds the two range checks — and produces **byte-identical JSON**.
Every stored `LocationSet` event decodes against the new type unchanged. There is no upcaster here
because there is no shape change; the only values that would newly fail are ones that were always
wrong.

The read model is the other half and it is not shape-preserving: collapsing `Customers.lat`/`lng` into
one `location` field rewrites the view's shape. That is a **projection rebuild, not an upcaster** —
a read model is derived state and replay is what it is for — and it is the whole point of the wave.
Doing the retype without the collapse would leave the pair in place, the heuristic still firing, and
the second statement of the fact still there: the type would have been *added* rather than having
*removed* anything, which is the test the analysis applies to every declaration.

**Core and the UI must be released and pinned together.** Between the collapse landing in core and the
declared-point role landing in the UI, the example's map mode has no pair to guess and no declaration
it can read, so it silently stops being offered. This is the only sequencing constraint in the wave,
and it is a hard one.

## Steps

**1 — `GeoPoint` in the semantic library.** `reventless/spec/src/semantic/GeoPoint.res`, following
`Money`'s template exactly: `latSchema`/`lngSchema` refining `S.float` from the single-statement
validators, the `@schema` record using them via `@s.matches`, then a `schema` shadowing the derived
one with `Semantic.mark(~id=Semantic.Id.geoPoint)`. Add `geoPoint` to `Semantic.Id` — camelCase, like
`dateRange` and `storageRef`, which means the UI accepts **two spellings** for one id (its own
vocabulary is kebab-case and already has `geo-point`). That is `DateRange`'s situation verbatim and
its resolution — both strings map to one constructor — is the one to copy.

**2 — the operations that make it a value object.** `validateLat` / `validateLng` (the single
statement of each range, returning `result` with a message quoting the offending number), `make`
returning `result`, `format`, `distanceTo`, `toGeoJson` / `fromGeoJson`. `format` is
locale-independent like every other formatter here — `"48.2082, 16.3738"`, latitude first, the order
a human reads — and the *other* order exists in exactly one place, the codec.

**3 — the example declares one, and gives the pair up.** Both halves, in one commit, because
separately they are each incoherent:

- `Customer.location` retypes from the local record to `Reventless.GeoPoint.t`; the local `location`
  type goes away. Command, event, behaviour, GWT fixtures.
- `Customers` collapses `lat: float, lng: float` into `location: option<Reventless.GeoPoint.t>` —
  `option` because a registered customer has no location until `LocationSet` arrives, which is what
  the `0.0, 0.0` placeholder was standing in for. That placeholder is its own small bug: `(0, 0)` is
  a real coordinate in the Gulf of Guinea, so every customer without a location is currently pinned
  there. `None` says the thing the zeros were pretending.
- the projection stops taking the value apart: `Update(id, state => {...state, location: Some(location)})`.
- the seed data set carries a point where it carried a pair.

**4 — the reader half, planned in the UI repo.** `autoui-geo-point-declared.md` in reventless-ui.
What this plan owes it is a contract, not a design:

| What the UI reads | Fixed by |
|---|---|
| the wire shape `{"lat": …, "lng": …}`, two numbers | the shape above — which is what its existing `shape:geo-point` rung and its existing `GeoInput` already key on, so neither waits on a release |
| the `geoPoint` marker on the field | step 1, reaching the UI as `x-reventless-semantic` |
| latitude first in text, longitude first only in GeoJSON | D1/D3 — a consumer that re-decides this will disagree with `toGeoJson` |
| the point may be absent | step 3's `option`, and the placeholder-coordinate reason above |

Two things that constrain what the type may become rather than how it is rendered. **A declared point
must outrank the name pair while the name pair survives**, so this is additive for every application
that gets a map today by naming its fields `lat`/`lng` — the same guarantee `DateRange` gave the
`start*`/`end*` pair. And **the `geo` role must become the thing the map reads**, not a second role
beside it: two ways to reach a marker is precisely the duplication being removed.

## Verification

- **A field typed `GeoPoint` emits `geoPoint`** — `SuryToJsonSchemaTest`, alongside the assertion that
  the field's JSON Schema `type` is `object` with two numeric sub-properties, the way the `money` and
  `dateRange` emissions are asserted rather than described.
- **Decode rejects an out-of-range coordinate**, both fields, both signs — the parity claim in D2
  stated as a test rather than a sentence, and the one thing `DateRange` could not assert.
- **`toGeoJson`/`fromGeoJson` round-trip, and the round trip is asserted on the *array order***:
  `coordinates` is `[lng, lat]`. A test that only checks `fromGeoJson(toGeoJson(p)) == p` passes with
  both ends swapped consistently, which is exactly the bug.
- **`distanceTo` against a known pair** — Vienna–Bratislava is ~55 km — with a tolerance that admits
  the spherical approximation and would still fail a radians/degrees slip by orders of magnitude.
- **The example round-trips through a live local platform, seed included**: the GraphQL input and
  output objects for the point, a `SetLocation` carrying one, and seeded customers arriving in a view
  whose map mode is offered *from the declaration*. `DateRange`'s verification is the model, including
  its own note that nobody looked at the rendered card — a marker in the wrong hemisphere is visible
  only in a browser.
- **Stored events decode unchanged across the retype** — the shape-preserving claim is the plan's
  cheapest-to-break assumption, so assert it directly: an event encoded by the *old* local record
  parses with the new schema.

The reader half's acceptance — every existing name-paired map keeps resolving, a declared point wins
where both exist, and a two-point fixture stops mispairing — belongs to the UI plan and is stated
there.

## Out of scope

- **Geometries beyond the point.** `GeoArea` (polygon), `GeoPath` (linestring) and the
  `FeatureCollection` around them are what the analysis's ZoneEditor/RouteView items need, and they
  are a different type each. `Point` is what the codec covers.
- **`Address`.** The structured postal shape is a separate composite and the *input* path to this one
  (geocode an address → a point). The UI's resolution already orders address ahead of geo-point for
  that reason; nothing here changes it.
- **Altitude, accuracy and bearing.** A third coordinate and an error radius are a different value —
  and adding them optionally to this record would make `{lat, lng}` stop being the whole of the point.
- **Geodesic accuracy.** Haversine on a sphere, per D4. An ellipsoidal distance belongs where the
  geodesy library does, not in a spec package.
- **Geohash / H3 / S2 indexing.** Tier 3 in the analysis, and a query concern rather than a value one.
- **The collapse of `lat`/`lng` pairs outside the hybrid example.** Additive elsewhere; the example is
  collapsed because it is the thing being proved.

## Follow-ups

- **A `boundingBox` / `within` pair**, the first time something filters by region rather than by
  radius. `distanceTo` answers proximity; a viewport query wants a box, and a box is a second type.
- **`Address` as the geocoding input**, which is what makes a point *enterable* by someone who does
  not know their coordinates. The map input covers click-to-place today.
- **Revisit `format`'s precision.** Six decimals is ~11 cm and is what most APIs emit; the formatter
  currently prints what the float has. Fix it the first time a log line is compared across platforms.
