/**
Spec for a composite display-name derivation.

`fields` names the source fields in declaration order; `separator` is inserted
between successive non-empty parts when `computeLabel` is applied.

The ppx attaches this spec to a state schema whenever one or more fields carry
the `@displayName` attribute. The projection runtime reads the spec at write
time and composes the label into a synthetic `displayName` field on state.
*/
type displayNameSpec = {
  fields: array<string>,
  separator: string,
}

/** Sury metadata ID used to attach a `displayNameSpec` to a state schema. */
let displayNameId: S.Metadata.Id.t<displayNameSpec> =
  S.Metadata.Id.make(~namespace="reventless", ~name="displayName")

/** Returns the spec attached to a state schema, if any. */
let getSpec = (schema: S.t<unknown>): option<displayNameSpec> =>
  S.Metadata.get(schema, ~id=displayNameId)

/**
Composes a display-name label from a state dict and a spec.

Reads each source field by name from the dict. Entries that are absent,
`null`, or empty strings are skipped. Remaining string values are joined
with `spec.separator`. The result never has a leading, trailing, or
doubled separator.
*/
let computeLabel = (spec: displayNameSpec, state: dict<JSON.t>): string =>
  spec.fields
  ->Array.filterMap(fieldName =>
    switch state->Dict.get(fieldName) {
    | Some(JSON.String(s)) if s != "" => Some(s)
    | _ => None
    }
  )
  ->Array.join(spec.separator)
