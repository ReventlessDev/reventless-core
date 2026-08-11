/**
The one place that knows how a row's GraphQL `id` relates to its storage key.

A read-side row is reachable through several id-accepting doors — the typed
`X(id: ID!)` query, `XsByIds(ids:)`, the list `filter.ids`, and Relay's
`node(id:)`. They used to disagree about which form they took, so the obvious
client call `X(id: row.id)` silently returned `null`: the door took the storage
key while the row advertised the Relay global id. The rule below is what
`QueryDbListQuery.passIds` already applied to `filter.ids` — lifted out so every
door applies it, and so provider adapters share one definition rather than three.

Provider-neutral on purpose: the contract belongs to neither the local platform
nor AWS.
*/

@val external btoa: string => string = "btoa"
@val external atob: string => string = "atob"

/** `btoa("<TypeName>:<localId>")` — the Relay global id for a row. */
let encode = (~typeName: string, ~localId: string): string => btoa(`${typeName}:${localId}`)

/**
The `(typeName, localId)` pair inside a global id, or `None` when the string is
not one. `atob` throws on non-base64 input; a decoded value with no `:` (or a
leading one, which would mean an empty type name) is not a global id either.
*/
let decode = (globalId: string): option<(string, string)> =>
  try {
    let decoded = atob(globalId)
    let idx = decoded->String.indexOf(":")
    if idx > 0 {
      Some((
        decoded->String.slice(~start=0, ~end=idx),
        decoded->String.slice(~start=idx + 1, ~end=decoded->String.length),
      ))
    } else {
      None
    }
  } catch {
  | _ => None
  }

/**
The storage key a global id wraps, or `None` if the string is not one.

Deliberately NOT a `string => string` that "normalises" an id: a raw key that
happens to be valid base64 would be silently rewritten into something that
matches nothing. Callers look the raw id up first and fall back to this — see
`alternateKey`.
*/
let toLocalId = (id: string): option<string> => decode(id)->Option.map(((_, localId)) => localId)

/**
The other key worth trying when a lookup by `id` found nothing: the storage key
inside it, if it was a global id. Ordering matters — the raw id is always tried
first, so a key that merely looks like base64 keeps resolving to its own row and
this only ever runs on a miss.
*/
let alternateKey = (id: string): option<string> =>
  switch toLocalId(id) {
  | Some(localId) if localId != id => Some(localId)
  | _ => None
  }
