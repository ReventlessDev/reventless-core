/**
The one marker every typed semantic marks itself with.

A semantic type says what a field's value *is* — a date-time, a reference to
another entity, a ref into an object store — as a property of the field's
**type**, not as a string stapled beside it. Every layer downstream then derives
from that single declaration: validation, the wire contract, the UI widget it
gets rendered with, and eventually the infrastructure provisioned for it.

Typed markers predate this module, and each was bespoke: `DateTime` carried its
own metadata id, `Reference` carried another, and the schema walk detected both
by hardcoded special case. That made every new typed marker new detection code.
One shared marker means the walk reads a semantic generically and a new semantic
type is a new *value*, not a new branch.

The payload is a real variant rather than free-form JSON. The semantic
vocabulary is framework-owned — an application declares a field *is* a storage
ref, it does not invent what a storage ref means — so the set is closed, and a
closed set typed here is one the compiler checks at every producer and consumer.
It also keeps `Reference.getTarget` a total typed function instead of a decode
that can fail at runtime.
*/

/** Which entity a reference field points to. */
type referenceTarget = {entity: string, plugin: option<string>}

/** Which object store a storage-ref field's value lives in. `plugin` is absent
    when the store belongs to the declaring plugin, which is the common case. */
type storeTarget = {plugin: option<string>, store: string}

/** Per-semantic detail, for the semantics that carry any. */
type payload =
  | Plain
  | ReferenceTo(referenceTarget)
  | StoredIn(storeTarget)

/** A field's semantic: the vocabulary id, plus its detail. */
type t = {id: string, payload: payload}

/**
The semantic ids the framework itself defines.

These strings are the wire vocabulary — they are what `x-reventless-semantic`
carries, and the same vocabulary the string annotation path already uses, so the
type path and the annotation path converge on one wire format rather than two.
*/
module Id = {
  let dateTime = "dateTime"
  let reference = "reference"
  let storageRef = "storageRef"
}

let semanticId: S.Metadata.Id.t<t> = S.Metadata.Id.make(~namespace="reventless", ~name="semantic")

/** Mark a schema as carrying a semantic. */
let mark = (schema: S.t<'a>, ~id: string, ~payload: payload=Plain): S.t<'a> =>
  schema->S.Metadata.set(~id=semanticId, {id, payload})

/** The semantic a field's schema carries, if any. */
let get = (fieldSchema: S.t<'a>): option<t> => S.Metadata.get(fieldSchema, ~id=semanticId)

/** Whether a field's schema carries this specific semantic. */
let has = (fieldSchema: S.t<'a>, ~id: string): bool =>
  switch get(fieldSchema) {
  | Some(s) => s.id === id
  | None => false
  }
