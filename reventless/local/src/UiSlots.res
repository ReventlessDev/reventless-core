// Serves the AutoUI slot module a deployment declared, where the local host
// shell serves its static assets from (`HostShellDist`).
//
// The same seam as `UiHints`, one file over: on AWS `uiSlotsFile` is read and
// written verbatim as a `BucketObject` beside `config.json`, and locally the
// declared file is copied into the served dist/ and watched, so editing a
// renderer is a browser refresh rather than a platform restart.
//
// Two things differ from the hints file, and both are why this is its own
// module rather than a parameter of that one.
//
// **There is no baseline, because there is nothing to protect.** The hints work
// had to reckon with the host-shell package shipping its own `ui-hints.json` as
// a dev fallback, which an undeclared platform goes on serving. The shell ships
// no slots module, so "undeclared" means "no file" with no third party's opinion
// underneath — and it should stay that way. A dev fallback here would be a
// fallback for *appearance*, and inheriting a stranger's appearance is exactly
// the failure that is hard to notice.
//
// So withdrawal removes the served file rather than restoring one. Any file at
// this path is one this module wrote: nothing else in the dist/ is named it, and
// the AWS bundle upload excludes the name for the same reason.
//
// **A broken module fails differently from broken hints.** Malformed hints
// decode leniently and the surface survives; a module that throws at import
// takes its whole registration with it. That is the shell's to report — log,
// skip, continue — and the only thing this side owes is not to make it worse by
// serving a stale copy after a failed edit. Hence no content check: serve what
// is on disk, and let the consumer say what it could not use.

let log = ReventlessCore.Logger.fromEnv()

// Shared with the AWS deploy and with both `config.json` writers, because the
// name the module is served under and the `uiSlotsUrl` naming it have to agree.
let fileName = ReventlessCore.Platform_UiSlots.fileName

/**
 Write the declared slot module into the served `dist/`, or remove a previously
 served one when nothing is declared.

 A no-op when there is nothing to say and nothing was said before, so a platform
 that declares no slots is byte-identical to one built before this existed.

 Once a file is declared the write happens or fails loudly: a path that does not
 resolve and a missing shell package are both the deployment's own mistake, and
 both produce the same symptom if swallowed — regions that quietly go on being
 drawn by their mode, which is indistinguishable from a renderer that was never
 written.

 What is deliberately *not* checked is the content. The deploy half cannot parse
 a module either, and a check that only ran locally would let a file pass the
 loop it was authored in and fail the one it ships to.
 */
let emit = (
  ~uiSlotsFile: option<string>,
  // Test seam, as in `UiHints.emit`: the removal on withdrawal is the part with
  // state behind it, and "declare, then withdraw, and the file is gone" is not a
  // property a pure function can carry.
  ~dir: option<string>=?,
) => {
  // Read before anything is touched, so a bad declaration cannot leave the
  // served file half-replaced.
  let declared = uiSlotsFile->Option.map(path =>
    switch NodeFs.readFileSync(path) {
    | contents => contents
    | exception _ =>
      JsError.throwWithMessage(
        `host UI ${fileName}: cannot read the declared uiSlotsFile at ${path} — ` ++
        `the shell imports this file at boot, so a declaration pointing nowhere ` ++
        `registers no renderers and says nothing about why.`,
      )
    }
  )

  switch (
    switch dir {
    | Some(_) as given => given
    | None => HostShellDist.dir()
    }
  ) {
  | None =>
    // No shell installed is the ordinary case for a platform nobody points a
    // browser at; only a declaration makes the missing package an error.
    if declared->Option.isSome {
      JsError.throwWithMessage(
        `host UI ${fileName}: cannot resolve ${HostShellDist.package} from ${NodeProcess.cwd()} — ` ++
        `the local shell imports its slot renderers from that package's dist/, so ` ++
        `declaring a uiSlotsFile without the package installed would write nothing ` ++
        `and leave every mode drawing its own regions.`,
      )
    }
  | Some(dir) =>
    let path = NodePath.join([dir, fileName])
    switch declared {
    | Some(contents) =>
      NodeFs.writeFileSync(path, contents)
      log.info(~comp="UiSlots", `wrote ${fileName} from the declared uiSlotsFile: ${path}`)
    | None =>
      // The counterpart to the hints baseline, and the reason this is a delete:
      // leaving yesterday's renderers in place with nothing in the diff to
      // explain them is the failure a baseline exists to prevent, and here the
      // state to return to is "no file".
      if NodeFs.existsSync(path) {
        NodeFs.unlinkSync(path)
        log.info(~comp="UiSlots", `removed ${fileName}: no uiSlotsFile is declared`)
      }
    }
  }
}

/**
 Re-copy the declared module into the served `dist/` whenever the file changes,
 so editing a renderer is a browser refresh rather than a platform restart.

 Local only, and deliberately so: on AWS the file is an object written once by a
 deploy, and "the running deployment follows my working copy" is not a thing a
 deployment should be able to do.

 **Failures here are logged, not thrown**, which is the one place this parts
 company with `emit`, for the reason `UiHints.watch` gives: at boot a declaration
 that does not resolve is the deployment's mistake and taking the process down is
 the point, while mid-session an unreadable file is almost always an editor
 saving in two steps, and killing a running dev server over a keystroke would
 make the feature worse than the restart it replaces.

 A module mid-save is a narrower window than a JSON file mid-save, because
 nothing here parses it: only a read that fails outright is caught, and a save
 that lands a syntactically broken module is served as written. That is the
 consumer's to report, and it reports it against the file the developer is
 looking at.

 `onReload` runs only after a re-copy actually succeeded, so a subscriber cannot
 be told to re-import a file that did not change.
 */
let watch = (
  ~uiSlotsFile: option<string>,
  ~dir: option<string>=?,
  ~onReload: unit => unit,
): option<NodeFs.watcher> =>
  uiSlotsFile->Option.flatMap(path => {
    // Named apart from the `~dir` above, which is where the file is SERVED. This
    // is where it is AUTHORED, and the two are never the same place — letting
    // one shadow the other would re-serve the module into the source tree beside
    // the file just edited.
    let sourceDir = NodePath.dirname(path)
    let base = NodePath.basename(path)
    if !NodeFs.existsSync(sourceDir) {
      // `emit` has already thrown on an unreadable declaration by the time this
      // is reached, so this is the narrow case of a path whose directory went
      // away between the two — worth a line, not worth a throw.
      log.warn(
        ~comp="UiSlots",
        `not watching ${base}: ${sourceDir} does not exist, so changes to the declared ` ++
        `uiSlotsFile will need a restart`,
      )
      None
    } else {
      // Editors coalesce badly: one save can raise `rename` and `change` within
      // a millisecond of each other, and re-copying twice would re-import twice.
      // The trailing timer collapses a burst into the single reload the
      // developer actually made.
      let pending = ref(None)
      let reload = () => {
        pending := None
        switch emit(~uiSlotsFile, ~dir?) {
        | () =>
          log.info(~comp="UiSlots", `${base} changed — re-served`)
          onReload()
        | exception JsExn(e) =>
          log.warn(
            ~comp="UiSlots",
            `${base} changed but could not be re-served: ` ++
            e->JsExn.message->Option.getOr("unknown error"),
          )
        }
      }
      let watcher = NodeFs.watch(sourceDir, (_event, filename) =>
        switch filename->Nullable.toOption {
        | Some(name) if name == base =>
          pending.contents->Option.forEach(clearTimeout)
          pending := Some(setTimeout(reload, 50))
        | _ => ()
        }
      )
      log.info(~comp="UiSlots", `watching ${path} — edits are served without a restart`)
      // Never the reason a process stays alive. A platform booted by a test that
      // happens to declare slots would otherwise hold the event loop open and
      // hang the run.
      Some(watcher->NodeFs.watcherUnref)
    }
  })
