// Serves the AutoUI hints file a deployment declared, where the local host
// shell serves its static assets from (`HostShellDist`).
//
// On AWS `uiHintsFile` is read and written verbatim as a `BucketObject` beside
// `config.json`, and the host-shell package's own `ui-hints.json` is excluded
// from the upload as the dev-mode fallback it is. Locally that fallback is in
// the mode it exists for, so an undeclared platform goes on serving it — but a
// declared file has to win, or the hints a deployment authors are the only ones
// its dev shell never applies.
//
// Hence the baseline, for the reason `ShellConfig` keeps one: without it a
// withdrawn declaration leaves yesterday's hints in place with nothing in the
// diff to explain them. Unlike `ShellConfig` there is no merge — AWS writes the
// declared file verbatim, and layering a deployment's hints over the shell
// package's demonstration hints would invent a third behaviour neither platform
// has.

let log = ReventlessCore.Logger.fromEnv()

let fileName = "ui-hints.json"

// Keeps the `.json` extension for the same reason `config.base.json` does: the
// dist is served as a static directory, and a dev can open the baseline in a
// browser to see what the declaration replaced.
let baselineFileName = "ui-hints.base.json"

/**
 Write the declared hints into the served `dist/`, or restore the shipped file
 when nothing is declared.

 A no-op when there is nothing to say and nothing was said before, so a platform
 that declares no hints is byte-identical to one built before this existed.
 Once a file is declared the write happens or fails loudly: a path that does not
 resolve, content that is not JSON, and a missing shell package are all the
 deployment's own mistake, and all three produce the same symptom if swallowed —
 hints that quietly are not applied.
 */
let emit = (
  ~uiHintsFile: option<string>,
  // Test seam, as in `ShellConfig.emit`: the baseline dance is the part with
  // state behind it, and "boot twice and the second write still starts from the
  // shipped file" is not a property a pure function can carry.
  ~dir: option<string>=?,
) => {
  // Read before anything is touched, so a bad declaration cannot leave the
  // served file half-replaced.
  let declared = uiHintsFile->Option.map(path => {
    let source = switch NodeFs.readFileSync(path) {
    | contents => contents
    | exception _ =>
      JsError.throwWithMessage(
        `host UI ${fileName}: cannot read the declared uiHintsFile at ${path} — ` ++
        `the shell fetches this file at boot, so a declaration pointing nowhere ` ++
        `applies no hints and says nothing about why.`,
      )
    }
    switch source->JSON.parseOrThrow {
    | _ => ()
    | exception _ =>
      JsError.throwWithMessage(
        `host UI ${fileName}: the declared uiHintsFile at ${path} is not JSON — ` ++
        `the shell warns once and applies no hints, which reads as hints that do nothing.`,
      )
    }
    source
  })

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
        `the local shell reads its hints from that package's dist/, so declaring a ` ++
        `uiHintsFile without the package installed would write nothing and leave the ` ++
        `shell applying whatever the package shipped.`,
      )
    }
  | Some(dir) =>
    let path = NodePath.join([dir, fileName])
    let baselinePath = NodePath.join([dir, baselineFileName])

    // Seeded only when there is something to replace it with. A platform that
    // declares nothing must not leave a baseline behind for the next one to
    // read as authoritative.
    if !NodeFs.existsSync(baselinePath) && declared->Option.isSome && NodeFs.existsSync(path) {
      NodeFs.writeFileSync(baselinePath, NodeFs.readFileSync(path))
    }

    switch declared {
    | Some(contents) =>
      NodeFs.writeFileSync(path, contents)
      log.info(~comp="UiHints", `wrote ${fileName} from the declared uiHintsFile: ${path}`)
    | None =>
      if NodeFs.existsSync(baselinePath) {
        NodeFs.writeFileSync(path, NodeFs.readFileSync(baselinePath))
        log.info(~comp="UiHints", `restored ${fileName} from ${baselineFileName}: ${path}`)
      }
    }
  }
}

/**
 Re-copy the declared hints into the served `dist/` whenever the file changes,
 so editing it is a browser refresh rather than a platform restart.

 Local only, and deliberately so: on AWS the file is an object written once by a
 deploy, and "the running deployment follows my working copy" is not a thing a
 deployment should be able to do. This is the dev loop, in the package that is
 the dev loop.

 **Failures here are logged, not thrown**, which is the one place this parts
 company with `emit`. At boot a declaration that does not resolve or does not
 parse is the deployment's mistake and taking the process down is the whole
 point. Mid-session it is almost always an editor: a save that writes in two
 steps is briefly a truncated file, and reading it at that instant is normal
 rather than wrong. Killing a running dev server over a keystroke would make the
 feature worse than the restart it replaces — so a bad read is reported and the
 previously served copy stands until the next event, which the save itself
 produces.

 `onReload` runs only after a re-copy actually succeeded, so a subscriber cannot
 be told to re-fetch a file that did not change.
 */
let watch = (
  ~uiHintsFile: option<string>,
  // The same seam `emit` takes, and threaded to it: a test has to be able to
  // watch a file it wrote into a temp dir without a host-shell package on disk.
  ~dir: option<string>=?,
  ~onReload: unit => unit,
): option<NodeFs.watcher> =>
  uiHintsFile->Option.flatMap(path => {
    // Named apart from the `~dir` above, which is where the file is SERVED. This
    // is where it is AUTHORED, and the two are never the same place — letting
    // one shadow the other would re-serve the hints into the source tree beside
    // the file just edited.
    let sourceDir = NodePath.dirname(path)
    let base = NodePath.basename(path)
    if !NodeFs.existsSync(sourceDir) {
      // `emit` has already thrown on an unreadable declaration by the time this
      // is reached, so this is the narrow case of a path whose directory went
      // away between the two — worth a line, not worth a throw.
      log.warn(
        ~comp="UiHints",
        `not watching ${base}: ${sourceDir} does not exist, so changes to the declared ` ++
        `uiHintsFile will need a restart`,
      )
      None
    } else {
      // Editors coalesce badly: one save can raise `rename` and `change` within
      // a millisecond of each other, and re-copying twice would publish twice
      // and restack the menu twice. The trailing timer collapses a burst into
      // the single reload the developer actually made.
      let pending = ref(None)
      let reload = () => {
        pending := None
        switch emit(~uiHintsFile, ~dir?) {
        | () =>
          log.info(~comp="UiHints", `${base} changed — re-served`)
          onReload()
        | exception JsExn(e) =>
          log.warn(
            ~comp="UiHints",
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
      log.info(~comp="UiHints", `watching ${path} — edits are served without a restart`)
      // Never the reason a process stays alive. A platform booted by a test
      // that happens to declare hints would otherwise hold the event loop open
      // and hang the run.
      Some(watcher->NodeFs.watcherUnref)
    }
  })
