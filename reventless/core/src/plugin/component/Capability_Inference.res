// Heuristic detection of fields that look like stored-object references but
// carry no `@storageRef` declaration.
//
// Declarations are authoritative: `Plugin_Structure` collects them into
// `requiredStores`, the capability manifest renders them, and the platform
// provisions from the union. This module is the second rung — the UI's
// field-name heuristics restated over the same schema walk — and it is a lint,
// not a mechanism: a heuristic match produces a warning naming the field and
// the annotation that would settle it, and never provisions anything. Guessing
// is a poor basis for creating and destroying infrastructure; a field named
// `imageUrl` is genuinely ambiguous between an uploaded object and an external
// URL, and only its author can say which.

/** One heuristic-only match: a field whose name says "stored object" on a
    component whose schema does not declare a store for it. */
type warning = {component: string, field: string}

// The two name rules the UI's semantic layer applies, restated here so the
// lint warns about exactly the fields the UI would silently upgrade to an
// upload input if an endpoint happened to exist. Matched case-insensitively
// and exactly (suffix rules aside): `customerFile` names a customer's file,
// not necessarily a stored object.
let refLikeNames = ["file", "attachment", "upload"]
let refLikeSuffixes = ["storageref", "fileref", "attachmentref"]
let imageLikeNames = ["image", "imageurl", "photo", "photourl", "avatar", "avatarurl", "thumbnail"]

let nameMatches = (field: string): bool => {
  let lower = field->String.toLowerCase
  refLikeNames->Array.includes(lower) ||
  imageLikeNames->Array.includes(lower) ||
  refLikeSuffixes->Array.some(suffix => lower->String.endsWith(suffix))
}

let warningsFromProperties = (~component, properties: dict<S.t<unknown>>): array<warning> =>
  properties
  ->Dict.toArray
  ->Array.filterMap(((field, fieldSchema)) =>
    switch fieldSchema {
    | String(_) if field != "TAG" &&
      nameMatches(field) &&
      Reventless.StorageRef.getStore(fieldSchema)->Option.isNone =>
      Some({component, field})
    | _ => None
    }
  )

/** Scan one component schema — a command/event union or a state object — for
    heuristic-only matches. The walk mirrors `Plugin_Structure`'s declared-store
    walk over the same schemas, so a field is either collected there (declared)
    or eligible to warn here, never both. */
let scanSchema = (~component: string, schema: S.t<unknown>): array<warning> => {
  let fromVariant = v =>
    switch v {
    | S.Object({properties}) => warningsFromProperties(~component, properties)
    | _ => []
    }
  switch schema {
  | Union({anyOf}) => anyOf->Array.flatMap(fromVariant)
  | other => fromVariant(other)
  }
}

/** The warning text: name the field, name the annotation that would settle it,
    and say what to do when the heuristic is wrong. */
let message = (w: warning): string =>
  `${w.component}.${w.field} looks like a stored-object reference but declares no store — ` ++
  `annotate it \`@storageRef("<store>")\` so the deployment provisions the store it needs, ` ++
  `or rename the field if it holds an external URL. Heuristic matches are never provisioned.`
