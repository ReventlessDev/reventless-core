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

  // The branded scalars. Each refines a `string` or a number without changing
  // its shape, so a field gains one of these without anything stored changing.
  let email = "email"
  let phone = "phone"
  let url = "url"
  let percent = "percent"
  let bytes = "bytes"
  let duration = "duration"
  let color = "color"

  // The first composite that is not infrastructure. Unlike the seven above it
  // this one changes a field's *shape* — a number becomes an object — so it is
  // a wire-breaking declaration rather than a refinement of one.
  let money = "money"

  // The second composite. A pair of ISO-8601 instants as one value, replacing a
  // span the UI used to guess from a `start*`/`end*` name pair. Like `money` it
  // is an object on the wire; unlike it, adopting it as a *new* optional field
  // is additive — an absent optional decodes to `None`.
  let dateRange = "dateRange"
}

let semanticId: S.Metadata.Id.t<t> = S.Metadata.Id.make(~namespace="reventless", ~name="semantic")

/** Mark a schema as carrying a semantic. */
let mark = (schema: S.t<'a>, ~id: string, ~payload: payload=Plain): S.t<'a> =>
  schema->S.Metadata.set(~id=semanticId, {id, payload})

/**
A schema that validates with `check` and carries the semantic `id`.

The branded scalars all have the same shape — one constructor function that
defines the grammar, and a schema that must agree with it — and `StorageRef`
established that the schema is *derived* from the constructor rather than
hand-rolling a second check beside it. Deriving it here makes that structural:
there is one place a grammar can be written, so there is nowhere for a second
one to drift.
*/
let refined = (base: S.t<'a>, ~id: string, ~check: 'a => result<'a, string>): S.t<'a> =>
  base
  ->S.refine(s => value =>
    switch check(value) {
    | Ok(_) => ()
    | Error(why) => s.fail(why)
    }
  )
  ->mark(~id)

/** A value as it should read back to the person who typed it. Rejection messages
    reach forms through `validateInput`, so they quote the offending value. */
let showString = (raw: string): string => raw->JSON.Encode.string->JSON.stringify

/**
The semantic a field's schema carries, if any.

An **optional** field keeps its marker one level down. The ppx annotates the
field's `string`, and sury-ppx then wraps that schema in a union with
`Undefined`/`Null`; the wrapper is a new schema and carries no metadata of its
own. So a walk that reads only the outer schema sees `imageUrl?: string` as
carrying no semantic at all — the store goes undeclared, the reference goes
uncollected, the branded scalar loses its brand. Every reader converges here, so
following the wrapper once here is what keeps "optional" a statement about
presence rather than a way to lose the field's type.

The outer schema is read first, so a marker set on the wrapper itself still wins.
Only a union with exactly one non-null variant is followed: that is the shape an
optional field has, and a genuine multi-variant union has no single inner schema
whose semantic could stand for the whole.
*/
let rec getFrom = (schema: S.t<unknown>): option<t> =>
  switch S.Metadata.get(schema, ~id=semanticId) {
  | Some(_) as found => found
  | None =>
    switch schema {
    | Union({anyOf}) =>
      switch anyOf->Array.filter(v =>
        switch v {
        | Null(_) | Undefined(_) => false
        | _ => true
        }
      ) {
      | [inner] => getFrom(inner)
      | _ => None
      }
    | _ => None
    }
  }

let get = (fieldSchema: S.t<'a>): option<t> => fieldSchema->S.castToUnknown->getFrom

/** Whether a field's schema carries this specific semantic. */
let has = (fieldSchema: S.t<'a>, ~id: string): bool =>
  switch get(fieldSchema) {
  | Some(s) => s.id === id
  | None => false
  }
