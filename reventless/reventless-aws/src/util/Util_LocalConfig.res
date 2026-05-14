// Reads optional `Pulumi.local.yaml` from the Pulumi project directory
// (process.cwd()). Each dev maintains their own copy with stack-specific
// overrides; the file is gitignored so per-dev values (e.g. an existing
// Cognito UserPool ID) stay off the checked-in `Pulumi.<stack>.yaml`.
// A key present here takes precedence over the same key in the stack file.
//
// Format: minimal `key: value` lines. Bare strings; optional `"…"` quoting;
// `#` introduces line / trailing comments; blank lines ignored. Not a full
// YAML parser — only this subset is supported by design (no nesting, no
// arrays, no multi-line scalars).

@module("fs") external existsSync: string => bool = "existsSync"
@module("fs") external readFileSync: (string, string) => string = "readFileSync"

let _filename = "Pulumi.local.yaml"
let _cache: ref<option<Dict.t<string>>> = ref(None)

let _stripQuotes = (s: string): string => {
  let n = String.length(s)
  if n >= 2 && String.startsWith(s, "\"") && String.endsWith(s, "\"") {
    String.substring(s, ~start=1, ~end=n - 1)
  } else {
    s
  }
}

let _parse = (content: string): Dict.t<string> => {
  let d = Dict.make()
  content
  ->String.split("\n")
  ->Array.forEach(rawLine => {
    let line = String.trim(rawLine)
    if line === "" || String.startsWith(line, "#") {
      ()
    } else {
      switch String.indexOf(line, ":") {
      | -1 => ()
      | idx =>
        let key = String.substring(line, ~start=0, ~end=idx)->String.trim
        let after = String.slice(line, ~start=idx + 1, ~end=String.length(line))
        let valuePart = switch String.indexOf(after, "#") {
        | -1 => after
        | hashIdx => String.substring(after, ~start=0, ~end=hashIdx)
        }
        let value = valuePart->String.trim->_stripQuotes
        if key !== "" {
          Dict.set(d, key, value)
        }
      }
    }
  })
  d
}

let _load = (): Dict.t<string> =>
  switch _cache.contents {
  | Some(d) => d
  | None =>
    let d = if existsSync(_filename) {
      _parse(readFileSync(_filename, "utf-8"))
    } else {
      Dict.make()
    }
    _cache := Some(d)
    d
  }

let get = (key: string): option<string> => Dict.get(_load(), key)
