let toJson: ('a, S.t<'a>) => JSON.t = (value, schema) =>
  value->S.decodeOrThrow(~from=schema->S.reverse, ~to=S.json)

let toJsonString: ('a, S.t<'a>, ~space: int) => string = (value, schema, ~space) =>
  value->S.decodeOrThrow(~from=schema->S.reverse, ~to=S.jsonStringWithSpace(space))

let fromJson: (JSON.t, S.t<'a>) => 'a = (json, schema) => json->S.parseOrThrow(~to=schema)

let fromJsonString: (string, S.t<'a>) => 'a = (str, schema) =>
  str->S.decodeOrThrow(~from=S.jsonString, ~to=schema)
