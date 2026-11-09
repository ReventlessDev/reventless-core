// Serves the catalogues a deployment declared, `i18n/<lang>.json`, where the local shell serves
// its static assets from (`HostShellDist`), merged as `Platform_I18n` merges them for the AWS
// deploy.
//
// Unlike `UiHints` there is no baseline to restore: the shell ships no `i18n/` directory, so a
// platform that stops declaring catalogues only has to remove what it wrote.

let log = ReventlessCore.Logger.fromEnv()

let dirName = "i18n"

let read: ReventlessCore.Platform_I18n.read = (~dir, ~language) => {
  let path = NodePath.join([dir, language ++ ".json"])
  NodeFs.existsSync(path) ? Some(NodeFs.readFileSync(path)) : None
}

/**
 Write every offered language's merged catalogue into the served directory, or remove the
 directory when nothing is declared.

 Fails loudly when a declaration is wrong — a tag that is not one, a source file that is not
 JSON, catalogues declared with no shell installed — for the reason `UiHints.emit` gives: each
 would otherwise read as a translation that quietly does nothing.
 */
let emit = (~i18n: option<ReventlessInfra.Platform.i18n>, ~dir: option<string>=?) => {
  let files = i18n->Option.map(i18n =>
    switch ReventlessCore.Platform_I18n.files(i18n, ~read) {
    | Ok(files) => files
    | Error(message) => JsError.throwWithMessage("host UI " ++ message)
    }
  )
  switch switch dir {
  | Some(_) as given => given
  | None => HostShellDist.dir()
  } {
  | None =>
    if files->Option.isSome {
      JsError.throwWithMessage(
        `host UI i18n: cannot resolve ${HostShellDist.package} from ${NodeProcess.cwd()} — ` ++ `declaring catalogues without the shell installed would serve them nowhere.`,
      )
    }
  | Some(dir) =>
    let served = NodePath.join([dir, dirName])
    switch files {
    | None =>
      if NodeFs.existsSync(served) {
        NodeFs.rmSync(served, {recursive: true, force: true})
        log.info(~comp="I18n", `removed ${served}: no catalogues declared`)
      }
    | Some(files) =>
      NodeFs.mkdirSync(served, {recursive: true})
      files->Array.forEach(((name, text)) => NodeFs.writeFileSync(NodePath.join([dir, name]), text))
      log.info(
        ~comp="I18n",
        `wrote ${files->Array.length->Int.toString} catalogue(s) into ${served}`,
      )
    }
  }
}

/**
 Re-merge whenever a source catalogue changes, so a confirmed translation shows on the next
 browser refresh rather than after a restart. Local only, as `UiHints.watch` is, and for the
 same reason a failure mid-session is logged rather than thrown: an editor's two-step save is
 briefly a truncated file.
 */
let watch = (~i18n: option<ReventlessInfra.Platform.i18n>, ~dir: option<string>=?): array<
  NodeFs.watcher,
> =>
  switch i18n {
  | None => []
  | Some(declared) =>
    let pending = ref(None)
    let reload = () => {
      pending := None
      switch emit(~i18n, ~dir?) {
      | () => log.info(~comp="I18n", "a catalogue changed — re-served")
      | exception JsExn(e) =>
        log.warn(
          ~comp="I18n",
          "a catalogue changed but could not be re-served: " ++
          e->JsExn.message->Option.getOr("unknown error"),
        )
      }
    }
    declared.sources->Array.filterMap(source =>
      if NodeFs.existsSync(source) {
        let watcher = NodeFs.watch(source, (_event, filename) =>
          switch filename->Nullable.toOption {
          | Some(name)
            if name->String.endsWith(".json") && !(name->String.endsWith(".lock.json")) =>
            pending.contents->Option.forEach(clearTimeout)
            pending := Some(setTimeout(reload, 50))
          | _ => ()
          }
        )
        Some(watcher->NodeFs.watcherUnref)
      } else {
        log.warn(~comp="I18n", `not watching ${source}: it does not exist`)
        None
      }
    )
  }
