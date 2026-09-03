/**
The set's rules, compiled once and called by every host: attach and remove are
idempotent, the primary is one of the set with the first attached standing in
until one is chosen, and a caption belongs to a member.

A host maps its own constructors onto `op` and `fact` and keeps the spec surface —
the variants, their annotations, its own refusals. Nothing here knows what an
entity is. `Attachments_Conformance` asserts these rules through a host.
*/

/** The stored file's reference. A `StorageRef` path today, so `string` carries it
    without a wrapper the host would have to unwrap on every arm. */
type ref = string

/**
How many members a host's set may hold.

Not a runtime variation: a graft fixes this once, and every command the graft
emits is shaped by the answer. It reaches `decide` as an argument rather than
sitting on `t` so that `empty` stays one value and a host that never mentions
cardinality gets the behaviour it has today.

Exactly one rule reads it — `Attach` — and that is the whole of the difference:
a bounded set replaces its member where an unbounded one appends beside it.
Everything else is already cardinality-blind. `SetPrimary` on a one-member set
resolves to a no-op through the rules it already has (the only member is already
the effective primary), which is why `Single` needs no branch for it and why the
scaffold simply declines to emit the command rather than the rules refusing it.
*/
// `@schema` so `Attachments_Scaffold`'s config can take this very type rather
// than a second spelling of it. A graft's config and the rule it selects being
// the same value is the point: a config that could say `"single"` where the
// rules say `Single` is a config that can be misspelled.
@schema
type cardinality =
  | /** An unbounded, ordered set: a gallery. */ Many
  | /** At most one member, replaced rather than added to. */ Single

/** Refolded per decision, never stored — a StateChangeSlice's state is. */
type t = {
  attached: array<ref>,
  /** Only the one chosen explicitly; see `effectivePrimary`. */
  primary: option<ref>,
  altTexts: array<(ref, string)>,
}

let empty = {attached: [], primary: None, altTexts: []}

/** What a host asks the set to do. */
type op =
  | /** `altText` is the caption a host may supply with the file itself. */
  Attach({ref: ref, altText: option<string>})
  | Remove({ref: ref})
  | /** Empty the set, whatever it holds.

        The op a bounded set's remove command maps onto: with one member there is
        no ref for the caller to name, and naming it would be asking them to
        repeat what the row already says. Well defined at either cardinality —
        an unbounded host that wants a "remove them all" command gets it here
        rather than by looping its own remove. */
  Clear
  | SetPrimary({ref: ref})
  | SetAltText({ref: ref, altText: string})
  | /** Caption whichever member is the primary, without naming it.

        The counterpart of `Clear`, and the op a bounded set's caption command
        maps onto — with one member there is nothing to name. It is not
        bounded-only, though: the primary is the one image a reader actually
        sees, so "caption the hero" is a command an unbounded host wants too,
        and resolving it here is what keeps the answer the same as the one
        `primaryWithAltText` gives a projection. */
  SetPrimaryAltText({altText: string})

/** What the set decided, for the host to name in its own event. */
type fact =
  | Attached({ref: ref, altText: option<string>})
  | Removed({ref: ref})
  | PrimarySet({ref: ref})
  | AltTextSet({ref: ref, altText: string})

/** The primary a reader should show: the one chosen, else the first attached, so
    a set never shows no file while it holds one. The read model applies the same
    rule over its own rows, which is why this takes the two values and not `t`. */
let primaryOf = (~chosen: option<ref>, ~attached: array<ref>) =>
  switch chosen {
  | Some(_) as p => p
  | None => attached->Array.get(0)
  }

let effectivePrimary = t => primaryOf(~chosen=t.primary, ~attached=t.attached)

let altTextOf = (t, ref) => t.altTexts->Array.find(((r, _)) => r == ref)->Option.map(((_, t)) => t)

/**
The primary and *its caption*, for a read model projecting the set onto a row.

The caption half is the reason this exists beside `primaryOf`. A view carries the
primary as a scalar because a card, a gallery tile and a reference cell each read
one image-semantic string per row — and it used to carry only the string, so the
caption stayed in the set's rows and the one image a reader actually sees, the
hero on the detail page, was the one image with no alternative text on it. An
accessibility hole produced by a projection, not by a missing command: the
caption was in the log the whole time.

Parameterised on accessors rather than owning the member type, because the field
holding a member's ref is named for the host's store (`productImage`) and the
member record is the host's own `@schema` type. `~ref` and `~altText` are the two
questions this rule has of a member, and passing them is what lets the rule be
compiled once while the shape stays the host's.

Takes `~chosen` — the explicitly chosen primary — rather than reading it off the
row, because a projection holds the scalar and the scalar is already the
fallback's answer. Passing the scalar back in is what makes "chosen, else the
first attached" stable across a remove that took the chosen one away.
*/
let primaryWithAltText = (
  ~chosen: option<ref>,
  ~members: array<'m>,
  ~ref: 'm => ref,
  ~altText: 'm => option<string>,
): (option<ref>, option<string>) => {
  let primary = primaryOf(~chosen, ~attached=members->Array.map(ref))
  (
    primary,
    primary->Option.flatMap(p => members->Array.find(m => ref(m) == p)->Option.flatMap(altText)),
  )
}

let evolve = (t, fact) =>
  switch fact {
  | Attached({ref, altText}) =>
    t.attached->Array.includes(ref)
      ? t
      : {
          ...t,
          attached: t.attached->Array.concat([ref]),
          altTexts: switch altText {
          | Some(text) => t.altTexts->Array.concat([(ref, text)])
          | None => t.altTexts
          },
        }
  | Removed({ref}) => {
      attached: t.attached->Array.filter(r => r != ref),
      primary: t.primary == Some(ref) ? None : t.primary,
      altTexts: t.altTexts->Array.filter(((r, _)) => r != ref),
    }
  | PrimarySet({ref}) => {...t, primary: Some(ref)}
  | AltTextSet({ref, altText}) => {
      ...t,
      altTexts: t.altTexts->Array.filter(((r, _)) => r != ref)->Array.concat([(ref, altText)]),
    }
  }

// Shared by the two captioning ops, which differ only in how they arrive at a
// ref. Spelled once so a named caption and the primary's caption cannot end up
// with different ideas of what a repeat is.
let setAltText = (t, ~ref, ~altText): result<array<fact>, [#NotAttached]> =>
  if !(t.attached->Array.includes(ref)) {
    Error(#NotAttached)
  } else if altTextOf(t, ref) == Some(altText) {
    Ok([])
  } else {
    Ok([AltTextSet({ref, altText})])
  }

/**
What the set decided, as facts in the order they happened.

`Ok([])` is the no-op a retried command must produce; the one refusal the set
owns is a primary or a caption on a ref it does not hold.

An array rather than one optional fact, because a bounded set replacing its
member decides two things at once — the old one leaves and the new one arrives —
and an event log records both. Collapsing them into a single "replaced" fact
would make a host declare an event that only bounded hosts have, which is one
more way the two cardinalities' emitted surfaces could diverge.
*/
let decide = (t, ~cardinality: cardinality=Many, op): result<array<fact>, [#NotAttached]> =>
  switch op {
  | Attach({ref, altText}) =>
    if t.attached->Array.includes(ref) {
      Ok([])
    } else {
      switch cardinality {
      | Many => Ok([Attached({ref, altText})])
      // The whole of what `Single` changes. The members that leave are named
      // individually rather than through `Clear` so the facts read the same
      // whether one was there or (through some history nothing produces) more.
      | Single =>
        Ok(
          Array.concat(
            t.attached->Array.map(r => Removed({ref: r})),
            [Attached({ref, altText})],
          ),
        )
      }
    }
  | Remove({ref}) => t.attached->Array.includes(ref) ? Ok([Removed({ref: ref})]) : Ok([])
  | Clear => Ok(t.attached->Array.map(r => Removed({ref: r})))
  | SetPrimary({ref}) =>
    if !(t.attached->Array.includes(ref)) {
      Error(#NotAttached)
    } else if effectivePrimary(t) == Some(ref) {
      Ok([])
    } else {
      Ok([PrimarySet({ref: ref})])
    }
  | SetAltText({ref, altText}) => setAltText(t, ~ref, ~altText)
  // An empty set has no primary, so there is nothing to caption — the same
  // refusal a named ref the set does not hold gets, and for the same reason.
  | SetPrimaryAltText({altText}) =>
    switch effectivePrimary(t) {
    | Some(ref) => setAltText(t, ~ref, ~altText)
    | None => Error(#NotAttached)
    }
  }
