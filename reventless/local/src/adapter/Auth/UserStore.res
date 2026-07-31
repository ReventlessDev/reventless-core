// In-memory user store loader. Hydrates `LocalAuth.Login.store` from
// three resolution paths (first match wins):
//   1. `~users` arg — explicit list passed by the caller
//   2. `~usersFile` arg — explicit YAML path
//   3. `.reventless/users.yaml` (relative to process.cwd()) — auto-discovery
//
// All three are silent on absence: when no path is provided and no default
// file exists, the store stays empty and `LocalAuth.Login.issue` rejects
// every credential. A one-line stdout hint is printed so developers know to
// either set the file or pass `~users` programmatically.

open Reventless

/**
 * One YAML entry. `groups` is required (use `[]` for an unprivileged user);
 * `userId` defaults to the username when omitted.
 */
@schema
type entry = {
  username: string,
  password: string,
  groups: array<string>,
  userId?: string,
}

// ── YAML parsing (eemeli/yaml) ──────────────────────────────────────────────

@module("yaml") external _yamlParse: string => unknown = "parse"

let _entriesSchema = S.array(entrySchema)

/** Parses a YAML document string into entries (best-effort). */
let parseString = (yamlText: string): result<array<entry>, string> =>
  try {
    let json = _yamlParse(yamlText)->Obj.magic
    Ok(S.parseOrThrow(json, _entriesSchema))
  } catch {
  | JsExn(err) => Error(JsExn.message(err)->Option.getOr("YAML parse error"))
  | _ => Error("YAML parse error")
  }

/** Reads + parses a YAML file. */
let parseFile = (path: string): result<array<entry>, string> =>
  try {
    let text = NodeFs.readFileSync(path)
    parseString(text)
  } catch {
  | JsExn(err) => Error(JsExn.message(err)->Option.getOr(`Cannot read ${path}`))
  | _ => Error(`Cannot read ${path}`)
  }

// ── Resolution & loading ────────────────────────────────────────────────────

let _registerEntries = (entries: array<entry>): unit =>
  entries->Array.forEach(({username, password, groups, ?userId}) => {
    let id: Identity.t = {
      userId: userId->Option.getOr(username),
      username,
      groups,
      provider: InMemory,
    }
    LocalAuth.Login.setCredentials(~username, ~password, ~identity=id)
  })

let _defaultPath = (): string => NodePath.join([NodeProcess.cwd(), ".reventless/users.yaml"])

/**
 * Hydrates the Login store. Returns the resolution path actually used
 * (`InlineUsers`, `UsersFile(path)`, `DefaultFile(path)`, or `Empty`).
 * Errors from a *resolved* path are returned as `Error`; absence of the
 * auto-discovered default file is silent.
 */
type resolution =
  | InlineUsers
  | UsersFile(string)
  | DefaultFile(string)
  | Empty

// Set on the first `load` call so `autoLoadOnce()` is a no-op once a caller
// has explicitly provided users. Tests can also flip it manually to suppress
// auto-discovery before `Platform.startServers`.
let resolved: ref<bool> = ref(false)

let resetResolution = (): unit => resolved := false

let load = (
  ~users: option<array<entry>>=?,
  ~usersFile: option<string>=?,
  (),
): result<resolution, string> => {
  resolved := true
  switch users {
  | Some(entries) =>
    _registerEntries(entries)
    Ok(InlineUsers)
  | None =>
    switch usersFile {
    | Some(path) =>
      parseFile(path)->Result.map(entries => {
        _registerEntries(entries)
        UsersFile(path)
      })
    | None =>
      let defaultPath = _defaultPath()
      if NodeFs.existsSync(defaultPath) {
        parseFile(defaultPath)->Result.map(entries => {
          _registerEntries(entries)
          DefaultFile(defaultPath)
        })
      } else {
        Console.log(
          "[LocalAuth] no users configured — POST /__inmemory/login will reject all. " ++
          "Provide ~users / ~usersFile or create .reventless/users.yaml relative to cwd.",
        )
        Ok(Empty)
      }
    }
  }
}

/**
 * Idempotent auto-discovery. Platform.startServers calls this before
 * `DomainGraphQL_Server.start`, so a `.reventless/users.yaml` in cwd
 * hydrates the Login store automatically. No-op once `load` has been
 * called from anywhere.
 */
let autoLoadOnce = (): unit =>
  if !resolved.contents {
    let _ = load()
  }
