// What a starter asks the registry before it starts a local platform: whether a
// reset would wipe a store something is serving, and whether to start at all.
// Scoped to <cwd>/.reventless/running/, so another app's store file is not
// covered. See docs/plans/done/one-local-platform-one-store.md.

// Naming a port IS the statement that this platform is meant to coexist — the
// escape hatch the runner and the e2e suites already take.
let bypassEnv = "REVENTLESS_DOMAIN_PORT"

let envNamed = (key: string): bool =>
  switch NodeProcess.env->Dict.get(key) {
  | Some(v) if v->String.trim != "" => true
  | _ => false
  }

type decision =
  | Start
  | AlreadyRunning(array<LocalPlatformRegistry.entry>)

/** Whether this process should go on to build a platform. `~cwd` is threaded so a
    test can exercise a registry without moving the whole process. */
let decide = (~cwd=NodeProcess.cwd(), ()): decision =>
  if envNamed(bypassEnv) {
    Start
  } else {
    switch LocalPlatformRegistry.list(~cwd, ()) {
    | [] => Start
    | entries => AlreadyRunning(entries)
    }
  }

// Through LocalSeedTarget, so the starters and the seed tools describe the same
// platform the same way.
let entryLine = (e: LocalPlatformRegistry.entry): string =>
  `→ already running at :${e.port->Int.toString}  ·  ${e.store->LocalSeedTarget.storeLabel}  (pid ${e.pid->Int.toString})`

/** What {!orAddressRunning} prints. Separate from the exit so it is testable. */
let report = (entries: array<LocalPlatformRegistry.entry>): array<string> =>
  switch entries {
  | [e] => [e->entryLine, `  nothing started — ${e.endpoint} is serving this directory.`]
  | entries =>
    Array.concat(
      [`→ ${entries->Array.length->Int.toString} platforms are already running in this directory:`],
      entries->Array.map(entryLine),
    )->Array.concat(["  nothing started — stop the ones you do not want, then start again."])
  }

/** The live platform serving this store file, if one is. Resolved against this
    process's cwd, because the registry's paths are absolute. */
let servedBy = (~path: string, ~cwd=NodeProcess.cwd(), ()): option<
  LocalPlatformRegistry.entry,
> => {
  let resolved = NodePath.resolve([path])
  LocalPlatformRegistry.list(~cwd, ())->Array.find(e => e.store.path == Some(resolved))
}

let refusalMessage = (~path: string, e: LocalPlatformRegistry.entry): string =>
  `refusing to reset ${path}: it is the store of ${e.app} running at :${e.port->Int.toString} (pid ${e.pid->Int.toString}). ` ++
  `Stop that platform first, or start this one without ?reset.`

/** Throws rather than letting a reset unlink a store something is serving. Always
    on: it must protect an app that never calls {!orAddressRunning}. */
let guardReset = (~path: string, ~cwd=NodeProcess.cwd(), ()): unit =>
  switch servedBy(~path, ~cwd, ()) {
  | Some(e) => JsError.throwWithMessage(refusalMessage(~path, e))
  | None => ()
  }

/** Start, or address the one already running. An app's `Main.res` calls this as
    its first line, before `Platform.Make()`. */
let orAddressRunning = (~cwd=NodeProcess.cwd(), ()): unit => {
  // The reset is checked first and throws: exit 0 is for a start that was merely
  // redundant, never for a destructive one that did not happen.
  switch Backend.fromEnv() {
  | Backend.Sqlite({path, resetOnStart: true}) => guardReset(~path, ~cwd, ())
  | Backend.Sqlite(_) | Backend.Memory | Backend.Postgres(_) => ()
  }
  switch decide(~cwd, ()) {
  | Start => ()
  | AlreadyRunning(entries) =>
    report(entries)->Array.forEach(Console.log)
    NodeProcess.exit(0)
  }
}
