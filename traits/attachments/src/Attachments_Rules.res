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
  | SetPrimary({ref: ref})
  | SetAltText({ref: ref, altText: string})

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

/** `Ok(None)` is the no-op a retried command must produce; the one refusal the set
    owns is a primary or a caption on a ref it does not hold. */
let decide = (t, op): result<option<fact>, [#NotAttached]> =>
  switch op {
  | Attach({ref, altText}) =>
    t.attached->Array.includes(ref) ? Ok(None) : Ok(Some(Attached({ref, altText})))
  | Remove({ref}) => t.attached->Array.includes(ref) ? Ok(Some(Removed({ref: ref}))) : Ok(None)
  | SetPrimary({ref}) =>
    if !(t.attached->Array.includes(ref)) {
      Error(#NotAttached)
    } else if effectivePrimary(t) == Some(ref) {
      Ok(None)
    } else {
      Ok(Some(PrimarySet({ref: ref})))
    }
  | SetAltText({ref, altText}) =>
    if !(t.attached->Array.includes(ref)) {
      Error(#NotAttached)
    } else if altTextOf(t, ref) == Some(altText) {
      Ok(None)
    } else {
      Ok(Some(AltTextSet({ref, altText})))
    }
  }
