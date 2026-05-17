// reventless-interop sits below reventless-spec (where the canonical
// `Util_Sury` shim lives) so it can't reach that copy. The shim is duplicated
// here verbatim — small enough that a tiny package-local copy beats wiring
// reventless-spec as a dependency just for four helpers.
//
// See reventless/reventless-spec/src/util/Util_Sury.res for the reference.
external toUnknown: 'a => unknown = "%identity"

let toJson: ('a, S.t<'a>) => JSON.t = (value, schema) =>
  toUnknown(value)->S.decodeOrThrow(~from=schema->S.reverse, ~to=S.json)

let toJsonString: ('a, S.t<'a>, ~space: int) => string = (value, schema, ~space) =>
  toUnknown(value)->S.decodeOrThrow(~from=schema->S.reverse, ~to=S.jsonStringWithSpace(space))

let fromJson: (JSON.t, S.t<'a>) => 'a = (json, schema) => json->S.parseOrThrow(~to=schema)

let fromJsonString: (string, S.t<'a>) => 'a = (str, schema) =>
  str->S.decodeOrThrow(~from=S.jsonString, ~to=schema)
