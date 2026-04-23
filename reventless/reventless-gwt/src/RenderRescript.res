// Renders a JSON value (produced by sury `Message.encode`) into ReScript
// source syntax — e.g. the JSON `{"TAG":"CategoryAdded","_0":{"name":"X"}}`
// becomes the string `CategoryAdded({name: "X"})`.
//
// A fully schema-driven renderer would walk `S.t<'a>` and recover every
// constructor name / record field type. Here we lean on sury's default JS
// representation instead:
//
//   - Payload-less variants encode to a bare string ("VariantName").
//   - Inlined-record variants encode to `{TAG: "Name", _0: {...}}` (BuckleScript
//     representation). A single-argument variant still uses `_0`.
//   - Multi-argument variants encode to `{TAG: "Name", _0: x, _1: y, ...}`.
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

and renderObject = (~level, dict: Dict.t<JSON.t>) => {
  let keys = dict->Dict.keysToArray
  switch dict->Dict.get("TAG") {
  | Some(tagJson) =>
    let tagName = switch tagJson {
    | String(s) => s
    | _ => "?"
    }
    let payloadKeys =
      keys->Array.filter(k => k != "TAG" && String.startsWith(k, "_"))
    switch payloadKeys {
    | [] => tagName
    | ["_0"] =>
      switch dict->Dict.get("_0") {
      | Some(p) => tagName ++ "(" ++ render(~level=level + 1, p) ++ ")"
      | None => tagName
      }
    | _ =>
      let ordered = payloadKeys->Array.toSorted((a, b) => {
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
    | _ =>
      let fields =
        keys
        ->Array.map(k => {
          let v = dict->Dict.getUnsafe(k)
          k ++ ": " ++ render(~level=level + 1, v)
        })
        ->Array.join(", ")
      "{" ++ fields ++ "}"
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
