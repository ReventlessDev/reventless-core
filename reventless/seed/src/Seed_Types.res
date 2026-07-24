// Argument values for a seeded mutation, and their GraphQL literal rendering.
//
// Seeding sends inline literals rather than declared variables, so any mutation
// can be called without generating a per-command variable signature. That means
// values have to know how to render themselves — in particular enums, which are
// bare identifiers in GraphQL and would be rejected if quoted like strings.

exception Failed(string)

type rec value =
  | String(string)
  | Id(string)
  | Int(int)
  | Float(float)
  | Bool(bool)
  /** Rendered unquoted — GraphQL enum values are identifiers, not strings. */
  | Enum(string)
  | List(array<value>)

let quote = (s: string): string => JSON.stringify(JSON.Encode.string(s))

let rec toLiteral = (v: value): string =>
  switch v {
  | String(s) | Id(s) => quote(s)
  | Int(i) => i->Int.toString
  | Float(f) => f->Float.toString
  | Bool(b) => b ? "true" : "false"
  | Enum(name) => name
  | List(items) => `[${items->Array.map(toLiteral)->Array.join(", ")}]`
  }

let ids = (xs: array<string>): value => List(xs->Array.map(x => Id(x)))
let strings = (xs: array<string>): value => List(xs->Array.map(x => String(x)))

/** One mutation call: the field name and its inline arguments. */
type mutation = {field: string, args: array<(string, value)>}

let mutation = (field: string, args: array<(string, value)>): mutation => {field, args}

let renderArgs = (args: array<(string, value)>): string =>
  args->Array.map(((k, v)) => `${k}: ${toLiteral(v)}`)->Array.join(", ")

/** Human-readable form used in progress output and failure messages. */
let describe = (m: mutation): string => `${m.field}(${renderArgs(m.args)})`
