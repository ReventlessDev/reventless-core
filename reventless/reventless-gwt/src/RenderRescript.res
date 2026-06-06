// Renders a JSON value (produced by sury `Message.encode`) into ReScript
// source syntax — e.g. the JSON `{"TAG":"CategoryAdded","_0":{"name":"X"}}`
// becomes the string `CategoryAdded({name: "X"})`.
//
// A fully schema-driven renderer would walk `S.t<'a>` and recover every
// constructor name / record field type. Here we lean on sury's default JS
// representation instead:
//
//   - Payload-less variants encode to a bare string ("VariantName").
//   - Single-argument variants encode to `{TAG: "Name", _0: x}`.
//   - Multi-argument variants encode to `{TAG: "Name", _0: x, _1: y, ...}`.
//   - Inline-record variants (`Name({a, b})`) are FLATTENED by ReScript: the
//     record fields sit beside TAG as `{TAG: "Name", a: ..., b: ...}`, NOT under
//     `_0`. These render back as `Name({a: ..., b: ...})`.
//   - Plain records encode to `{field: value, ...}`.
//   - Arrays/tuples encode to JSON arrays.
//
// That's enough to produce readable failure diagnostics for every GWT DSL
// shipped so far. A later pass can replace this with a sury-schema walker
// for the last 10% of cases (abstract or sealed types, custom schemas).

let escapeString = (s: string) => {
  let escaped =
    s
    ->String.replaceAll("\\", "\\\\")
    ->String.replaceAll("\"", "\\\"")
    ->String.replaceAll("\n", "\\n")
    ->String.replaceAll("\r", "\\r")
    ->String.replaceAll("\t", "\\t")
  "\"" ++ escaped ++ "\""
}

let indent = (level: int) => String.repeat("  ", level)

let rec render = (~level=0, j: JSON.t): string =>
  switch j {
  | Null => "None"
  | Boolean(true) => "true"
  | Boolean(false) => "false"
  | String(s) => escapeString(s)
  | Number(n) => Float.toString(n)
  | Array(arr) => renderArray(~level, arr)
  | Object(dict) => renderObject(~level, dict)
  }

and renderArray = (~level, arr: array<JSON.t>) =>
  switch arr {
  | [] => "[]"
  | _ =>
    let inner = arr->Array.map(render(~level=level + 1, _))->Array.join(", ")
    "[" ++ inner ++ "]"
  }

and renderRecord = (~level, keys: array<string>, dict: Dict.t<JSON.t>) => {
  let fields =
    keys
    ->Array.map(k => {
      let v = dict->Dict.getUnsafe(k)
      k ++ ": " ++ render(~level=level + 1, v)
    })
    ->Array.join(", ")
  "{" ++ fields ++ "}"
}

and renderObject = (~level, dict: Dict.t<JSON.t>) => {
  let keys = dict->Dict.keysToArray
  switch dict->Dict.get("TAG") {
  | Some(tagJson) =>
    let tagName = switch tagJson {
    | String(s) => s
    | _ => "?"
    }
    // Positional args are `_0`, `_1`, …; an inline-record variant instead
    // flattens its record fields beside TAG (no `_`-prefixed keys).
    let positional = keys->Array.filter(k => k != "TAG" && String.startsWith(k, "_"))
    let inlineFields = keys->Array.filter(k => k != "TAG" && !String.startsWith(k, "_"))
    switch positional {
    | [] =>
      switch inlineFields {
      | [] => tagName
      | _ => tagName ++ "(" ++ renderRecord(~level, inlineFields, dict) ++ ")"
      }
    | ["_0"] =>
      switch dict->Dict.get("_0") {
      | Some(p) => tagName ++ "(" ++ render(~level=level + 1, p) ++ ")"
      | None => tagName
      }
    | _ =>
      let ordered = positional->Array.toSorted((a, b) => {
        let parseTail = k =>
          String.slice(k, ~start=1, ~end=String.length(k))
          ->Int.fromString
          ->Option.getOr(0)
        Int.compare(parseTail(a), parseTail(b))
      })
      let parts =
        ordered
        ->Array.map(k => render(~level=level + 1, dict->Dict.getUnsafe(k)))
        ->Array.join(", ")
      tagName ++ "(" ++ parts ++ ")"
    }
  | None =>
    switch keys {
    | [] => "{}"
    | _ => renderRecord(~level, keys, dict)
    }
  }
}

let renderMany = (arr: array<JSON.t>): string =>
  switch arr {
  | [] => "[]"
  | [one] => "[" ++ render(one) ++ "]"
  | _ =>
    let inner =
      arr->Array.map(v => indent(1) ++ render(~level=1, v))->Array.join(",\n")
    "[\n" ++ inner ++ ",\n]"
  }

// Render an optional JSON as either a ReScript value or the sentinel "None".
let renderOption = (o: option<JSON.t>): string =>
  switch o {
  | Some(j) => render(j)
  | None => "None"
  }
