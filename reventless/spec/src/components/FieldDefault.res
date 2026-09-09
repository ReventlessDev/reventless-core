/**
The value a field opens with where nobody has said otherwise, published as JSON
Schema's own `default` keyword.

A statement about the domain: an order line is for one of the thing unless the
shopper says two. A consumer that finds no default opens the field blank rather
than inventing one.

Write `@default(1)` — see `DefaultInference`, which desugars to the constructors
below. The marker rides on the field's own schema rather than in a record-level
spec keyed by field name, which is what makes it work at any depth: a record
nested inside a command carries no such spec, and its fields are the ones a
repeating group opens blank.

@example
```rescript
@schema
type lineItem = {
  @ref("AvailableProducts") productId: string,
  @default(1) quantity: int,
}
```
*/
let defaultId: S.Metadata.Id.t<JSON.t> = S.Metadata.Id.make(
  ~namespace="reventless",
  ~name="default",
)

/** Layers a default onto whatever the field already resolved to. Wraps rather
    than replaces, for the reason `Sensitive.mark` does: a field carries at most
    one `@s.matches`. */
let mark = (schema: S.t<'a>, value: JSON.t): S.t<'a> => schema->S.Metadata.set(~id=defaultId, value)

let int = (schema: S.t<int>, value: int): S.t<int> => schema->mark(JSON.Encode.int(value))

let float = (schema: S.t<float>, value: float): S.t<float> => schema->mark(JSON.Encode.float(value))

let string = (schema: S.t<string>, value: string): S.t<string> =>
  schema->mark(JSON.Encode.string(value))

let bool = (schema: S.t<bool>, value: bool): S.t<bool> => schema->mark(JSON.Encode.bool(value))

/** The default a field declares. An optional field keeps its marker inside the
    wrapper sury builds for `f?: t`, so the outer schema is read first and a
    marker on the wrapper wins — the precedence `Semantic.getFrom` follows. */
let rec getFrom = (schema: S.t<unknown>): option<JSON.t> =>
  switch S.Metadata.get(schema, ~id=defaultId) {
  | Some(_) as found => found
  | None => schema->Semantic.unwrapOptional->Option.flatMap(getFrom)
  }

let get = (fieldSchema: S.t<'a>): option<JSON.t> => fieldSchema->S.castToUnknown->getFrom
