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
 *
 * The shape belongs to [AccountsManifest] rather than to this adapter: the AWS
 * provisioning tool writes the same file, and two definitions of one file format
 * is how a manifest starts working on one platform and failing on the other.
 */
type entry = AccountsManifest.entry

let parseString = AccountsManifest.parseString
let parseFile = AccountsManifest.parseFile

// ── Resolution & loading ────────────────────────────────────────────────────

/** The usernames the accounts file gave, so a reload can forget those it no
    longer lists without touching accounts registered some other way. */
let fromFile: ref<array<string>> = ref([])

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

let _defaultPath = AccountsManifest.defaultPath

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

/** Set once a plugin has been built, and with it the check that every role it
    needs has a group among these accounts. */
let pluginChecked: ref<bool> = ref(false)

let resetResolution = (): unit => {
  resolved := false
  pluginChecked := false
  fromFile := []
}

/**
The groups the store's accounts will belong to, for the role check, which runs
before the servers start and load it: the loaded accounts once `load` has run,
otherwise the default file `autoLoadOnce` will read (or the template `setup`
makes it from). Never the working directory once another source was loaded.
*/
let providedGroups = (): array<string> =>
  LocalAuth.knownGroups()->Array.concat(resolved.contents ? [] : AccountsManifest.declaredGroups())

let load = (~users: option<array<entry>>=?, ~usersFile: option<string>=?, ()): result<
  resolution,
  string,
> => {
  // The default file is what the check already read; any other source arrives
  // after it, and the check would have compared the plugins with other accounts.
  if pluginChecked.contents && (users->Option.isSome || usersFile->Option.isSome) {
    JsError.throwWithMessage(
      "UserStore.load(~users / ~usersFile) after a plugin was built — the check that every role it needs has a group read other accounts. Call UserStore.load before deploying plugins.",
    )
  }
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
        fromFile := entries->Array.map(e => e.username)
        UsersFile(path)
      })
    | None =>
      let defaultPath = _defaultPath()
      if NodeFs.existsSync(defaultPath) {
        parseFile(defaultPath)->Result.map(entries => {
          _registerEntries(entries)
          fromFile := entries->Array.map(e => e.username)
          DefaultFile(defaultPath)
        })
      } else {
        Console.log(
          "[LocalAuth] no users configured — POST /__inmemory/login will reject all. " ++ "Provide ~users / ~usersFile or create .reventless/users.yaml relative to cwd.",
        )
        Ok(Empty)
      }
    }
  }
}

// ── Reloading ───────────────────────────────────────────────────────────────

/**
Reads the accounts file again: accounts it adds can sign in, changed ones sign in
with their new password and groups, and ones it no longer lists are forgotten. A
token already issued stays valid until it expires, as it carries its identity.
A file that does not parse changes nothing, so a half-saved edit never signs
everyone out. Says what it did, for the log.
*/
let reload = (path: string): result<string, string> =>
  switch parseFile(path) {
  | Error(e) => Error(e)
  | Ok(entries) =>
    let names = entries->Array.map(e => e.username)
    let dropped = fromFile.contents->Array.filter(n => !(names->Array.includes(n)))
    dropped->Array.forEach(username => LocalAuth.Login.removeCredentials(~username))
    _registerEntries(entries)
    fromFile := names
    Ok(
      `${names->Array.length->Int.toString} accounts` ++ (
        dropped == [] ? "" : `, removed: ${dropped->Array.join(", ")}`
      ),
    )
  }

/** The roles the plugins need that the accounts no longer provide, as the
    platform's start would have refused them; empty when all are provided. */
let unmetAfterReload = (): array<RoleCoverage.need> =>
  switch Role.providedGroups() {
  | None => []
  | Some(provided) => RoleCoverage.unmet(RoleCoverage.checked.contents, ~provided)
  }

let _watcher: ref<option<NodeFs.watcher>> = ref(None)
let _pending: ref<option<timeoutId>> = ref(None)

/** Stops following the accounts file. */
let unwatch = (): unit => {
  _watcher.contents->Option.forEach(NodeFs.watcherClose)
  _watcher := None
  _pending.contents->Option.forEach(clearTimeout)
  _pending := None
}

/**
Follows the accounts file, so an account the tools or the developer add can sign
in without a restart. The folder is watched, not the file, as an editor that
saves by replacing the file would silence a watch on it. One save fires several
events; they are read once, a moment after the last.
*/
let watch = (path: string): unit => {
  unwatch()
  let dir = NodePath.dirname(path)
  let base = NodePath.basename(path)
  let last = ref(NodeFs.existsSync(path) ? NodeFs.readFileSync(path) : "")
  switch NodeFs.watch(dir, (_, file) =>
    if file->Nullable.toOption->Option.mapOr(true, f => f == base) {
      _pending.contents->Option.forEach(clearTimeout)
      _pending := Some(setTimeout(() => {
            _pending := None
            switch NodeFs.readFileSync(path) {
            | text if text != last.contents =>
              last := text
              switch reload(path) {
              | Ok(said) =>
                Console.log(`[LocalAuth] ${base} changed — reloaded ${said}.`)
                switch unmetAfterReload() {
                | [] => ()
                | missing =>
                  Console.warn(
                    `[LocalAuth] No account is in the group of: ` ++
                    missing
                    ->Array.map(RoleCoverage.describe)
                    ->Array.join("; ") ++ ". Every such caller is refused until one is.",
                  )
                }
              | Error(e) => Console.warn(`[LocalAuth] ${base} changed but was not read: ${e}`)
              }
            | _ => ()
            | exception _ => ()
            }
          }, 100))
    }
  ) {
  | w => _watcher := Some(w->NodeFs.watcherUnref)
  | exception _ => ()
  }
}

/**
 * Idempotent auto-discovery. Platform.startServers calls this before
 * `DomainGraphQL_Server.start`, so a `.reventless/users.yaml` in cwd
 * hydrates the Login store automatically, and follows the file from then on.
 * No-op once `load` has been called from anywhere.
 */
let autoLoadOnce = (): unit =>
  if !resolved.contents {
    switch load() {
    | Ok(DefaultFile(path)) | Ok(UsersFile(path)) => watch(path)
    | _ => ()
    }
  }
