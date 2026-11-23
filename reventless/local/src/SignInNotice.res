// Serves a short notice the sign-in page shows under its title, where the local
// host shell serves its static assets from (`HostShellDist`).
//
// The notice is written by whoever is developing the app, not declared by the
// deployment: `.reventless/sign-in-notice.json` in the platform's working
// directory, shaped `{"text": "..."}`, one plain-text string. It says what the
// app's sign-in needs right now ("Nobody can sign in to this app yet.", then who
// can), which changes while the platform runs, so the file is followed from the
// start whether or not it exists yet.
//
// Local only. There is no counterpart on AWS, where nothing in the working
// directory reaches a deployed bucket.
//
// Like the slot module there is no baseline: the shell ships no notice, so "no
// file" is the state to return to, and a served file at this name is one this
// module wrote.
//
// Unlike the declared hints and slots, a bad file never stops the platform, at
// the start or later. It is not the deployment's declaration but a working note
// another program rewrites while the app runs; a file that does not read is
// logged and the copy served before it stands.

let log = ReventlessCore.Logger.fromEnv()

/** The name of the source in `.reventless/` and of the copy served beside `config.json`. */
let fileName = "sign-in-notice.json"

/** Where the shell fetches the notice: the dist root is its URL root. */
let url =
  "/" ++ fileName

/** The `config.json` key naming `url`. */
let configKey = "signInNoticeUrl"

/** The source in the platform's working directory. */
let sourcePath = (): string => NodePath.join([NodeProcess.cwd(), ".reventless", fileName])

/**
 The source to follow: the default one, when its `.reventless` folder exists.
 That folder is never created here, so a directory without one (a test's) stays
 without one and its `config.json` names no notice.
 */
let followed = (): option<string> => {
  let path = sourcePath()
  NodeFs.existsSync(NodePath.dirname(path)) ? Some(path) : None
}

/** The text of a notice file, or why it is not one. */
let parse = (contents: string): result<string, string> =>
  switch contents->JSON.parseOrThrow->JSON.Decode.object {
  | Some(obj) =>
    switch obj->Dict.get("text")->Option.flatMap(JSON.Decode.string) {
    | Some(text) => Ok(text)
    | None => Error(`${fileName} has no "text" string`)
    }
  | None => Error(`${fileName} is not a JSON object`)
  | exception _ => Error(`${fileName} is not JSON`)
  }

/**
 Serve the notice `source` holds into `dir`, or remove the served copy when
 `source` does not exist.

 Writes `{"text": ...}` only, whatever else the source holds, so the shell reads
 one shape. A source that does not read or parse leaves the served copy as it
 was and says why. Without a shell to serve from there is nothing to do.
 */
let emit = (~source: string, ~dir: option<string>=?): result<unit, string> =>
  switch switch dir {
  | Some(_) as given => given
  | None => HostShellDist.dir()
  } {
  | None => Ok()
  | Some(dir) =>
    let path = NodePath.join([dir, fileName])
    if NodeFs.existsSync(source) {
      switch NodeFs.readFileSync(source) {
      | contents =>
        contents
        ->parse
        ->Result.map(text => {
          NodeFs.writeFileSync(
            path,
            JSON.stringify(
              Dict.fromArray([("text", JSON.Encode.string(text))])->JSON.Encode.object,
            ),
          )
          log.info(~comp="SignInNotice", `wrote ${fileName}: ${path}`)
        })
      | exception _ => Error(`cannot read ${source}`)
      }
    } else {
      if NodeFs.existsSync(path) {
        NodeFs.unlinkSync(path)
        log.info(~comp="SignInNotice", `removed ${fileName}: ${source} does not exist`)
      }
      Ok()
    }
  }

/**
 Re-serve the notice whenever its source is written or removed, so the sign-in
 page can follow it without a restart.

 The folder is watched, not the file, so a source that does not exist yet is
 picked up when it is written, and an editor that saves by replacing the file
 does not silence the watch. One save fires several events; they are served
 once, a moment after the last.

 `onReload` runs only after a re-serve succeeded, so a subscriber is never told
 to re-fetch a file that did not change.
 */
let watch = (~source: string, ~dir: option<string>=?, ~onReload: unit => unit): option<
  NodeFs.watcher,
> => {
  let sourceDir = NodePath.dirname(source)
  let base = NodePath.basename(source)
  if !NodeFs.existsSync(sourceDir) {
    None
  } else {
    let pending = ref(None)
    let reload = () => {
      pending := None
      switch emit(~source, ~dir?) {
      | Ok() =>
        log.info(~comp="SignInNotice", `${base} changed — re-served`)
        onReload()
      | Error(e) =>
        log.warn(~comp="SignInNotice", `${base} changed but could not be re-served: ${e}`)
      }
    }
    switch NodeFs.watch(sourceDir, (_event, filename) =>
      switch filename->Nullable.toOption {
      | Some(name) if name == base =>
        pending.contents->Option.forEach(clearTimeout)
        pending := Some(setTimeout(reload, 50))
      | _ => ()
      }
    ) {
    | watcher =>
      log.info(~comp="SignInNotice", `watching ${source} — the sign-in page follows it`)
      // Never the reason a process stays alive.
      Some(watcher->NodeFs.watcherUnref)
    | exception _ => None
    }
  }
}
