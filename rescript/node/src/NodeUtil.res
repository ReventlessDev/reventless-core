/** Bindings for `node:util`. `parseArgs` is stable from Node 20.

    Node's string enums are regular variants whose constructors compile to the
    exact strings Node reads and writes. `default` and `allowNegative` are left
    out: the first is a string, a boolean or an array depending on the option,
    and the second needs Node 22.4. */
/** An option's `type`. */
type optionType =
  | @as("string") String
  | @as("boolean") Boolean

type optionConfig = {
  @as("type") type_: optionType,
  short?: string,
  multiple?: bool,
}

type config = {
  args?: array<string>,
  options: dict<optionConfig>,
  strict?: bool,
  allowPositionals?: bool,
  tokens?: bool,
}

/** A token's `kind`. The constructor names avoid `Option`, which would read as
    the standard library module at every use site. */
type tokenKind =
  | @as("option") Flag
  | @as("positional") Positional
  | @as("option-terminator") Terminator

type token = {
  kind: tokenKind,
  index: int,
  name?: string,
  rawName?: string,
  value?: string,
  inlineValue?: bool,
}

/** `values` mixes strings, booleans and arrays under one object, so it is
    abstract and read through the typed accessors below. */
type values

type parsed = {values: values, positionals: array<string>, tokens?: array<token>}

@module("node:util") external parseArgs: config => parsed = "parseArgs"

@get_index external string: (values, string) => option<string> = ""
@get_index external bool: (values, string) => option<bool> = ""
@get_index external strings: (values, string) => option<array<string>> = ""
