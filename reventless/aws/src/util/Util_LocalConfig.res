// Deploy-time per-instance overrides for Pulumi-config-shaped keys. Two
// sources, layered (highest precedence first):
//
//   1. **Environment variable** named `REVENTLESS_<KEY_IN_SCREAMING_SNAKE>`.
//      Wins over everything. Intended for CI runners where the value comes
//      from a repository / environment secret. An empty string is treated
//      as "not set" so a stray empty export does not mask the sidecar.
//   2. **`Pulumi.local.yaml`** sidecar in the Pulumi project directory
//      (`process.cwd()`). Gitignored — intended for dev-local overrides.
//
// Callers fall back to Pulumi stack config (or auto-provision) when `get`
// returns `None`.
//
// Env-var naming: camelCase key → `REVENTLESS_<SCREAMING_SNAKE>`.
// Example: `cognitoUserPoolId` → `REVENTLESS_COGNITO_USER_POOL_ID`.
//
// Sidecar format: minimal `key: value` lines. Bare strings; optional
// `"…"` quoting; `#` introduces line / trailing comments; blank lines
// ignored. Not a full YAML parser — only this subset is supported by
// design (no nesting, no arrays, no multi-line scalars).

@module("fs") external existsSync: string => bool = "existsSync"
@module("fs") external readFileSync: (string, string) => string = "readFileSync"
@module("path") external pathJoin: (string, string) => string = "join"
@module("path") external pathDirname: string => string = "dirname"
@val @scope("process") external processCwd: unit => string = "cwd"
@val external processEnv: Dict.t<string> = "process.env"

let _filename = "Pulumi.local.yaml"
let _projectFile = "Pulumi.yaml"
let _cache: ref<option<Dict.t<string>>> = ref(None)

// Pulumi sets the Node program's cwd to the directory containing the `main`
// entry (typically `src/`), not the project directory. Walk up from cwd to
// find Pulumi.yaml, then read Pulumi.local.yaml next to it.
let _findSidecar = (): option<string> => {
  let rec find = dir => {
    if existsSync(pathJoin(dir, _projectFile)) {
      let candidate = pathJoin(dir, _filename)
      existsSync(candidate) ? Some(candidate) : None
    } else {
      let parent = pathDirname(dir)
      parent == dir ? None : find(parent)
    }
  }
  find(processCwd())
}

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
    let d = switch _findSidecar() {
    | Some(path) => _parse(readFileSync(path, "utf-8"))
    | None => Dict.make()
    }
    _cache := Some(d)
    d
  }

let _envVarName = (key: string): string => {
  let buf = ref("REVENTLESS")
  let n = String.length(key)
  for i in 0 to n - 1 {
    let ch = String.charAt(key, i)
    let upper = String.toUpperCase(ch)
    let isLetter = upper !== String.toLowerCase(ch)
    let isUpper = isLetter && ch === upper
    if i === 0 || isUpper {
      buf := buf.contents ++ "_" ++ upper
    } else {
      buf := buf.contents ++ upper
    }
  }
  buf.contents
}

let get = (key: string): option<string> =>
  switch Dict.get(processEnv, _envVarName(key)) {
  | Some(v) if v !== "" => Some(v)
  | _ => Dict.get(_load(), key)
  }
