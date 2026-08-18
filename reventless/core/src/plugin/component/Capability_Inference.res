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
  | AnyOf({anyOf}) => anyOf->Array.flatMap(fromVariant)
  | other => fromVariant(other)
  }
}

/** The warning text: name the field, name the annotation that would settle it,
    and say what to do when the heuristic is wrong. */
let message = (w: warning): string =>
  `${w.component}.${w.field} looks like a stored-object reference but declares no store — ` ++
  `annotate it \`@storageRef("<store>")\` so the deployment provisions the store it needs, ` ++
  `or rename the field if it holds an external URL. Heuristic matches are never provisioned.`

// ── Near-duplicate stores ──────────────────────────────────────────────────
//
// Under name-derived stores a typo does not fail, it *provisions*: `productImage`
// and `productImgae` both compile, both deploy, and objects split silently
// across two buckets. Nothing else in the pipeline can see the mistake — both
// are well-formed declarations — so the check has to live where every store a
// plugin declares is visible at once.
//
// Unlike the heuristic lint above this is a hard failure, and it is meant to be:
// a warning about infrastructure that was already created is a warning nobody
// can act on cheaply. A pair that is genuinely two stores settles it by naming
// one explicitly with `@storageRef("<store>")`.

/** Two store declarations close enough that one is likely a typo for the other. */
type collision = {
  a: Reventless.Plugin.requiredStoreDeclaration,
  b: Reventless.Plugin.requiredStoreDeclaration,
}

// Exactly the optimal-string-alignment distance ≤ 1: one insert, one delete, one
// substitution, or one transposition. Written directly rather than as a general
// distance because a transposition is the shape the motivating typo has
// (`Images` → `Imgaes`), and a plain Levenshtein scores that 2 and misses it.
let withinOneEdit = (a: string, b: string): bool => {
  let (la, lb) = (String.length(a), String.length(b))
  let charAt = (s, i) => String.charAt(s, i)
  if la == lb {
    let diffs = []
    for i in 0 to la - 1 {
      if charAt(a, i) != charAt(b, i) {
        diffs->Array.push(i)
      }
    }
    switch diffs {
    | [] => true
    | [_] => true
    | [i, j] if j == i + 1 =>
      charAt(a, i) == charAt(b, j) && charAt(a, j) == charAt(b, i)
    | _ => false
    }
  } else if la - lb == 1 || lb - la == 1 {
    // The longer string with one character removed must equal the shorter one.
    let (long, short) = la > lb ? (a, b) : (b, a)
    let rec scan = (~li, ~si, ~skipped) =>
      if si >= String.length(short) {
        true
      } else if charAt(long, li) == charAt(short, si) {
        scan(~li=li + 1, ~si=si + 1, ~skipped)
      } else if skipped {
        false
      } else {
        scan(~li=li + 1, ~si, ~skipped=true)
      }
    scan(~li=0, ~si=0, ~skipped=false)
  } else {
    false
  }
}

/** Whether two store names are the same word in different number. Reached only
    through an explicit `@storageRef` override — a derived name is already
    pluralised through its singular stem, so two *derived* names cannot differ
    this way. */
let sameStem = (a: string, b: string): bool =>
  Api_Naming.singularize(a) == Api_Naming.singularize(b)

// The unqualified store name and its owning plugin, split off the qualified key
// the declarations carry.
let splitKey = (key: string): (string, string) =>
  switch key->String.split(".") {
  | [plugin, store] => (plugin, store)
  | _ => ("", key)
  }

/**
Pairs of declared stores that are probably one store misspelled twice.

Compared within an owning plugin only: two plugins may legitimately hold stores
whose names are one edit apart, and neither can be a typo for the other.
*/
let collisions = (
  declarations: array<Reventless.Plugin.requiredStoreDeclaration>,
): array<collision> => {
  // One entry per store, keeping the first declaration site as the one the
  // message names — several fields naming one store is ordinary, not a clash.
  let byStore: dict<Reventless.Plugin.requiredStoreDeclaration> = Dict.make()
  declarations->Array.forEach(d =>
    switch byStore->Dict.get(d.store) {
    | Some(_) => ()
    | None => byStore->Dict.set(d.store, d)
    }
  )
  let unique = byStore->Dict.valuesToArray
  let found = []
  for i in 0 to Array.length(unique) - 1 {
    for j in i + 1 to Array.length(unique) - 1 {
      let a = unique->Array.getUnsafe(i)
      let b = unique->Array.getUnsafe(j)
      let (pluginA, storeA) = splitKey(a.store)
      let (pluginB, storeB) = splitKey(b.store)
      if pluginA == pluginB && (withinOneEdit(storeA, storeB) || sameStem(storeA, storeB)) {
        found->Array.push({a, b})->ignore
      }
    }
  }
  found
}

/** The failure text: name both stores and both declaration sites, so a pair that
    is genuinely two stores is diagnosed in one reading. */
let collisionMessage = (c: collision): string =>
  `${c.a.store} (${c.a.component}.${c.a.field}) and ${c.b.store} ` ++
  `(${c.b.component}.${c.b.field}) differ by one edit — one is probably a typo for ` ++
  `the other, and both would be provisioned, splitting objects across two stores. ` ++
  `Fix the field name, or name the store explicitly with \`@storageRef("<store>")\` ` ++
  `if the two really are separate stores.`
