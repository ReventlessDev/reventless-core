/**
Marks a field whose value must not be rendered into content a person receives.

`@sensitive` is a *position*, not a type: it says "whatever this field holds, do
not put it in an outbound message". What the field **is** — an email, a token, a
reference — is declared separately, exactly as owning and tagging are separate
facts about one field.

It is declared where the field is declared, and read by anything that composes
text somebody will read. That is the whole reason it lives here rather than
beside whichever consumer happens to need it first: a marking that exists in one
consumer is a marking the rest of the system cannot honour, and the domain model
is the only place that knows which values are sensitive.

## Absent means "not stated", not "safe"

A reader that misses the marker leaks the value, so the failure is *open* — the
same shape as `Owner`, and the reason `isFieldSensitive` follows the wrappers
rather than leaving each consumer to unwrap for itself.

## Some fields need no annotation

A field whose semantic already says it is a contact detail is sensitive without
anybody writing it down — see `impliedBySemantic`. The annotation is for the
values a type cannot betray: a token, a note, a reference somebody chose.

`@sensitive` is the authoring form and is sugar over the constructors below, the
way `@owner` is sugar over `Owner`'s. Write `@s.matches(Sensitive.mark(…))` by
hand where the ppx shorthand cannot reach — a file with no `@@reventless.spec`
annotation, or a field whose type is neither `string` nor `option<string>`.

@example
```rescript
@schema type event =
  PasswordReset({
    @owner customerId: string,
    @sensitive resetToken: string,
  })
```
*/
let sensitiveId: S.Metadata.Id.t<bool> = S.Metadata.Id.make(
  ~namespace="reventless",
  ~name="sensitive",
)

/**
Layers the marker onto a schema that already says something else.

Sensitivity is independent of everything else a field declares — it may equally
be a DCB tag, an owner, or a reference — but a field carries at most one
`@s.matches`, so this composes by *wrapping* what the field already resolved to
rather than replacing it. Replacing would silently drop the field's tag, and a
dropped tag is a decision read that quietly misses events.
*/
let mark = (schema: S.t<'a>): S.t<'a> => schema->S.Metadata.set(~id=sensitiveId, true)

/** A string field that must not be rendered outbound. */
let string: S.t<string> = S.string->mark

/**
An `option<string>` field that must not be rendered outbound.

Needed because `@s.matches` on an explicitly-`option`-typed field must supply the
whole field schema, wrapper included. The `f?: string` form needs nothing extra:
sury wraps the annotated inner schema itself, and `isFieldSensitive` looks
through that wrapper either way.
*/
let optionString: S.t<option<string>> = S.option(string)

/** Whether this exact schema carries the marker. Does not look through wrappers. */
let isSensitive = (schema: S.t<unknown>): bool =>
  S.Metadata.get(schema, ~id=sensitiveId)->Option.getOr(false)

/**
Whether a *field* is sensitive, wherever inside the field's type the marker sits.

An optional field keeps its marker inside the union wrapper, so a walk reading
only the outer schema answers `false` for `token?: string` — and here that means
the value is rendered into a message rather than withheld. Object properties are
deliberately not followed, for the same reason `Owner` does not follow them: a
marker on a nested record's field belongs to that field, and attributing it to
the enclosing one would withhold a whole record because one leaf is private.
*/
let isFieldSensitive = (schema: S.t<unknown>): bool =>
  isSensitive(schema) ||
    switch schema->Semantic.unwrapOptional {
    | Some(inner) => isSensitive(inner)
    | None => false
    }

/**
The sensitive fields declared on an object schema, in declaration order.

Threaded to the JSON-Schema walk the way `Owner.fieldNames` is, and for the same
reason: the IR is shape-driven and sensitivity is not a shape — the field stays a
plain string either way. Reading it off the sury schema here also keeps it
available on command and event variants, which carry no annotation spec.
*/
let fieldNamesOfProperties = (properties: dict<S.t<unknown>>): array<string> =>
  properties
  ->Dict.toArray
  ->Array.filterMap(((propName, propSchema)) =>
    isFieldSensitive(propSchema) ? Some(propName) : None
  )

let fieldNames = (schema: S.t<unknown>): array<string> =>
  switch schema {
  | Object({properties}) => fieldNamesOfProperties(properties)
  | _ => []
  }

/**
The sensitive fields of one constructor of a command or event union.

The form a renderer actually needs: it composes text about **one** occurrence, so
only that variant's fields have anything to say. `OrderPlaced` and
`PasswordReset` live in the same union and know nothing about each other's
fields — resolving by TAG here rather than at the call site is what stops a
template from consulting the wrong arm.

Answers `[]` for an unknown tag and for a payload-less variant, both of which
mean the same thing to a caller: nothing on this event is withheld.
*/
let variantFieldNames = (schema: S.t<unknown>, ~variant: string): array<string> =>
  schema->Semantic.unionVariant(~variant)->Option.mapOr([], fieldNames)

/**
The semantics that are sensitive without an annotation.

A contact detail is one whether or not anybody remembered to mark it, so the
rule is stated once here rather than left to each consumer to remember. Kept
deliberately short: it holds only the semantics whose *whole meaning* is "how to
reach a particular person". A postal address or a display name can be sensitive
in context, and context is exactly what an annotation is for.
*/
let impliedBySemantic = (semanticId: string): bool =>
  semanticId === Semantic.Id.email || semanticId === Semantic.Id.phone
