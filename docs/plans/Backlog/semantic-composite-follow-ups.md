# Plan: the open edges of the `DateRange` and `GeoPoint` composites

**Date:** 2026-10-07<br/>
**Status:** Backlog — extracted from [../done/semantic-date-range.md](../done/semantic-date-range.md) and [../done/semantic-geo-point.md](../done/semantic-geo-point.md) when they closed (their "Follow-ups" sections). Each item waits for a trigger named below; only the first can be checked today.<br/>
**Relates to:** [semantic-time-of-day.md](semantic-time-of-day.md)

---

## In plain words

`DateRange` (two instants, `[start, end)`) and `GeoPoint` (`{lat, lng}`) are
semantic composites in `reventless/spec/src/semantic/`: record types the
framework recognises, with a marker the UI reads and value-object operations
beside them. Both shipped and are used by the hybrid example. These are the
decisions both plans deliberately left for evidence.

## 1. Move `DateRange`'s ordering rule into the schema — checkable now

`start <= end` relates two fields, so it can only be a refinement on the whole
record. sury 11.0.0-alpha.4 miscompiled that, so the rule lives only in
`DateRange.validate` / `make`, and decode accepts a reversed range. The module
doc and `reventless/spec/tests/DateRangeTest.res` say so.

The repo has since moved to **sury 11.0.0** (`reventless/spec/package.json`). Run
a ReScript spike (not a JS one — the plan explains why a JS reconstruction proves
nothing): refine `DateRange.schema` on the record and decode a reversed range. If
it is refused, move the rule into the schema with `validate` as its single
definition (as `Money.validateAmount` / `amountSchema`), and flip the test that
asserts decode lets it through. Note that this test will **not** fail by itself
when sury is fixed — nothing refines the record yet — so it needs doing on purpose.

## 2. `DateRange`: store `Duration`, or keep deriving it

`DateRange.duration` derives the length. Storing it too states one fact twice,
but a query filtering by length cannot compute it. Decide the first time a view
filters or sorts by a range's length.

## 3. `DateRange`: an open-ended range

Both ends are required; an unfinished interval is a start field beside an
`option<DateRange.t>`. Revisit if two adopters end up keeping that pair, which is
the evidence the plan named for allowing a missing `end`.

## 4. `GeoPoint`: a bounding box

`distanceTo` answers proximity. A viewport or region filter wants a box (`within`,
`boundingBox`), which is a second type. Add it the first time something filters
by region rather than by radius.

## 5. `GeoPoint.format` precision

`format` prints whatever the float holds (`Float.toString`). Six decimals (~11 cm)
is what most services emit. Fix it the first time a formatted point is compared
across platforms or logs.

## Done already, for the record

- The live local round trip `GeoPoint` owed was covered by the `Geolocation`
  work (a `GeoPoint` inside `Located`, verified locally and deployed).
- `Address` as the geocoding input to a point shipped as
  `traits/address-geocoding`.
