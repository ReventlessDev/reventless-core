/**
A short code the platform makes, which a person reads, copies or types back, and
which finds one record: a booking reference, a member number, the token a charger
knows a customer by.

It is not a secret. It is shown to the person it belongs to, stored as it is, and
found by its value. A code that proves something, such as a confirmation code sent
by e-mail, is a secret instead: hash it with `Secrets.hash` and compare digests.

## The type and the marker

The type says what the value is, wherever it travels: the command that presents a
code, the event that records it, the view that shows it. One command field, the one
that makes the code, is marked **issued**:

- the write path **fills** an issued field with a new code from the platform's
  `Secrets` source before the command is published, replacing whatever a caller
  sent, so nobody picks a guessable code or someone else's;
- an exempt caller (the platform's own traffic, an operator) keeps a non-empty
  value it sends, which is how example data and migrations carry codes of their
  own, and gets a new code when it sends none;
- the field is optional for callers: the API's argument may be left out, and a
  form asks nothing for it.

The code is made before the command's handler runs and travels in its payload, so
the decision sees a value like any other, the event records it, and replaying the
history gives the same code.

## Finding a record by its code

Tag the field of the event that records the code with `tag`, so the decision of a
command that presents a code reads that event, and refuses a code it does not find.
The tag's key is the field's name.

@example
```rescript
@schema type command =
  | SignUp({
      @partitionTag driverId: string,
      chargingToken: @s.matches(Reventless.ReferenceCode.issued) Reventless.ReferenceCode.t,
    })

@schema type event =
  | DriverSignedUp({
      driverId: string,
      chargingToken: @s.matches(Reventless.ReferenceCode.tag) Reventless.ReferenceCode.t,
    })
```
*/
/** The code as it is. Transparent `string`: typing an existing field with it changes
    nothing stored. */
type t = string

external unsafe: string => t = "%identity"
external toString: t => string = "%identity"

/** The schema of a code wherever it travels: any text, taken as it is, carrying the
    semantic `referenceCode`. Codes from example data, a migration or another system
    keep their own shape. */
let schema: S.t<t> =
  S.string->Semantic.mark(~id=Semantic.Id.referenceCode)

let issuedId: S.Metadata.Id.t<bool> = S.Metadata.Id.make(~namespace="reventless", ~name="issued")

/** Marks a schema as the field the platform fills. Layers onto whatever the schema
    already says, as `Owner.mark` does. */
let markIssued = (schema: S.t<'a>): S.t<'a> => schema->S.Metadata.set(~id=issuedId, true)

/** The command field that makes the code: `@s.matches(Reventless.ReferenceCode.issued)`. */
let issued: S.t<t> = schema->markIssued

/** The event field a code is found by: the code's schema with a DCB tag keyed by the
    field's name. `@s.matches(Reventless.ReferenceCode.tag)`. */
let tag: S.t<t> =
  schema->DcbTag.markDeclared

/** Whether this exact schema carries the issued marker. Does not look through wrappers. */
let isIssued = (schema: S.t<unknown>): bool =>
  S.Metadata.get(schema, ~id=issuedId)->Option.getOr(false)

/** Whether a field is issued, wherever inside the field's type the marker sits: an
    optional field keeps it inside the union wrapper. */
let isFieldIssued = (schema: S.t<unknown>): bool =>
  isIssued(schema) ||
  switch schema->Semantic.unwrapOptional {
  | Some(inner) => isIssued(inner)
  | None => false
  }

/** The issued fields declared on an object schema, in declaration order. */
let fieldNamesOfProperties = (properties: dict<S.t<unknown>>): array<string> =>
  properties
  ->Dict.toArray
  ->Array.filterMap(((name, schema)) => isFieldIssued(schema) ? Some(name) : None)

let fieldNames = (schema: S.t<unknown>): array<string> =>
  switch schema {
  | Object({properties}) => fieldNamesOfProperties(properties)
  | _ => []
  }

/** The issued fields of one constructor of a command union, by its tag: only the
    variant being issued is filled. `[]` for an unknown tag and for a payload-less
    variant. */
let variantFieldNames = (schema: S.t<unknown>, ~variant: string): array<string> => {
  let isVariant = (properties: dict<S.t<unknown>>) =>
    switch properties->Dict.get("TAG") {
    | Some(String({const: ?Some(name)})) => name == variant
    | _ => false
    }
  switch schema {
  | AnyOf({anyOf}) =>
    anyOf
    ->Array.find(v =>
      switch v {
      | Object({properties}) => isVariant(properties)
      | _ => false
      }
    )
    ->Option.mapOr([], v =>
      switch v {
      | Object({properties}) => fieldNamesOfProperties(properties)
      | _ => []
      }
    )
  // A single-constructor command compiles to a bare object rather than a union.
  | Object({properties}) => isVariant(properties) ? fieldNamesOfProperties(properties) : []
  | _ => []
  }
}

/** How many characters a made code has: sixty bits of the `Readable` alphabet. */
let length = 12

/** A drawn code in groups of four, as a person reads it out: `7KQ3-X9MD-4TPA`. */
let grouped = (raw: string): string =>
  raw
  ->String.split("")
  ->Array.reduceWithIndex("", (out, c, i) => out ++ (i > 0 && mod(i, 4) == 0 ? "-" : "") ++ c)
