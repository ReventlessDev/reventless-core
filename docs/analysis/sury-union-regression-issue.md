# Regression in 11.0.0-rc.0: union members declared after a group of ≥2 object members are unreachable

**Filed 2026-08-18 as [DZakh/sury#392](https://github.com/DZakh/sury/issues/392).**
Kept here as the source text; edit upstream, not here.

---

Since `11.0.0-rc.0` the union parser groups a contiguous run of two or more object
members into one inner dispatch block, but guards that block with "is this an object?"
instead of the discriminants it actually handles, and ends it with a `break` out of the
outer dispatch. So every object enters the group, one whose tag the group does not know
throws there, and members declared after the group are dead code.

ReScript variants are hit directly, since they compile to exactly the shape being
grouped (`{TAG, _0}`).

## Reproduction

```rescript
type payload = {a: string, kind: string}

type t =
  | One(string)
  | Two(string)
  | Three(payload)
  | Four(string)

// all that matters is that this payload's schema contains a union
let payloadSchema = S.schema(s => ({
  a: s.matches(S.string),
  kind: s.matches(S.union([S.literal("A"), S.literal("B")])),
}: payload))

let schema = S.union([
  S.schema(s => One(s.matches(S.string))),
  S.schema(s => Two(s.matches(S.string))),
  S.schema(s => Three(s.matches(payloadSchema))),
  S.schema(s => Four(s.matches(S.string))),
])

let check = (label, value) => {
  let json = value->S.decodeOrThrow(~from=schema, ~to=S.json)
  switch json->S.parseOrThrow(~to=schema) {
  | _ => Console.log(label ++ " OK")
  | exception S.Exn(e) => Console.log(label ++ " FAIL  " ++ e.message)
  }
}

let () = {
  check("One  ", One("x"))
  check("Two  ", Two("x"))
  check("Three", Three({a: "x", kind: "A"}))
  check("Four ", Four("x"))
}
```

Expected: all four round-trip. Actual:

```
One   OK
Two   OK
Three FAIL  Expected { TAG: "One"; _0: string; } | … | { TAG: "Four"; _0: string; },
            received { TAG: "Three"; _0: object; }
Four  FAIL  Expected { TAG: "One"; _0: string; } | … | { TAG: "Four"; _0: string; },
            received { TAG: "Four"; _0: "x"; }
```

`Four`'s payload is a plain `S.string` — it fails only because it is declared after
`Three`, and the error lists `{ TAG: "Four"; _0: string; }` among the expected members.
Encoding is unaffected, so values are written correctly and then cannot be read back.

## Cause

`S.parser` output for the schema above:

```js
i => { for(;;) {
  if (typeof i === "object" && i && !Array.isArray(i)) {   // ← guard omits the TAG
    for(;;) {
      if (i["TAG"] === "One") { … break }
      if (i["TAG"] === "Two") { … break }
      e[2](i)                        // ← every other object throws here
    };
    break                            // ← and this exits the outer dispatch
  }
  if (… && i["TAG"] === "Three") { … }   // unreachable for any object
  if (… && i["TAG"] === "Four")  { … }   // unreachable for any object
} return i }
```

A member is excluded from the group when its payload schema contains a union — which
includes `S.option` and `S.null` fields. A group needs at least two members to form, and
only strands members when it is not the last group, so moving the union-bearing member
to the *end* does not help.

## Workaround

Declare union-bearing members first. For a hand-written schema only the
`S.union([...])` order matters — the variant type can stay as it is:

```rescript
let schema = S.union([
  S.schema(s => Three(s.matches(payloadSchema))),   // moved up
  S.schema(s => One(s.matches(S.string))),
  S.schema(s => Two(s.matches(S.string))),
  S.schema(s => Four(s.matches(S.string))),
])
```

If several members are union-bearing, all of them must move — one left further down
re-creates a non-final group. Serialization is unchanged by member order, so this is
wire-compatible.

## Versions

Parses on 10.0.0 through 11.0.0-alpha.11; fails on 11.0.0-rc.0 and 11.0.0-rc.1. (The
bisect used the equivalent plain-JS schema, since the ReScript API changed across that
range.) Consistent with this, the grouped-dispatch codegen is absent from every
published bundle through `alpha.11` and present from `rc.0` — the regression is the
introduction of the grouping optimization.

## Environment

sury `11.0.0-rc.1` (also `rc.0`) · rescript `12.3.0` · Node.js v22.17.1 · macOS
