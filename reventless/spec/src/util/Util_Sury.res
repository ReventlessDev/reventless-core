// Sury-version isolation seam. Wraps the sury 11 conversion API behind stable
// names so each call site is a mechanical rename from the removed alpha.4 helpers
// (`reverseConvertToJsonOrThrow` / `parseJsonOrThrow` / …), and a future sury bump
// is a one-file change. Signatures verified against sury@11.0.0-alpha.8 (S.resi):
// `parseOrThrow(~to)` / `decodeOrThrow(~from, ~to)` with labeled args; there is no
// `S.encoder` in the ReScript API — encoding goes `decodeOrThrow(~from=schema, ~to=S.json)`.
// See docs/plans/sury-11-migration.md.

let toJson: ('a, S.t<'a>) => JSON.t = (value, schema) =>
  value->S.decodeOrThrow(~from=schema, ~to=S.json)

// `~space` defaults to compact, matching the removed `reverseConvertToJsonStringOrThrow`.
let toJsonString = (value: 'a, schema: S.t<'a>, ~space: int=0): string =>
  value->S.decodeOrThrow(
    ~from=schema,
    ~to=space == 0 ? S.jsonString : S.jsonStringWithSpace(space),
  )

let fromJson: (JSON.t, S.t<'a>) => 'a = (json, schema) => json->S.parseOrThrow(~to=schema)

let fromJsonString: (string, S.t<'a>) => 'a = (str, schema) =>
  str->S.decodeOrThrow(~from=S.jsonString, ~to=schema)

// Sury raises `S.Exn`, which carries `RE_EXN_ID: "S.Exn"` and so is not a `JsExn`
// even though it is a JS Error at runtime — the usual
// `JsExn.fromException->flatMap(JsExn.message)` yields None and the reason is
// logged as "unknown". Reach for this at any site that catches a decode.
let exnMessage = (exn: exn, ~fallback: string="unknown"): string =>
  switch exn {
  | S.Exn(e) => e.message
  | _ => exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr(fallback)
  }
