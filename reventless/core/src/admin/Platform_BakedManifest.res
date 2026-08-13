// Curation for the baked component manifest: a deployment's include-list applied
// to the registered plugin structures, encoded through the very same encoder
// `Platform_ComponentDefinitions` uses.
//
// Curation is not authorization. This module decides WHAT EXISTS for a
// deployment's audience — deployment data, settled before anyone logs in. What a
// caller may do stays a server-side decision, enforced per query and per
// mutation, and nothing here relaxes it. That split is the reason a curated file
// can be static at all.
//
// The filtering happens on the `pluginStructure` record, never on the encoded
// JSON: whatever survives is then handed to
// `Platform_ComponentDefinitionsApi.encodePluginStructureEntry`, so a baked entry
// and a served entry cannot drift in shape, and an include-list that names
// everything produces byte-identical output.

open Reventless.Plugin

type error =
  | UnknownPlugin(string)
  | UnknownView({plugin: string, view: string})
  | UnknownCommand({plugin: string, command: string})

let describe = (e: error): string =>
  switch e {
  | UnknownPlugin(plugin) => `baked manifest: no registered plugin named "${plugin}"`
  | UnknownView({plugin, view}) =>
    `baked manifest: plugin "${plugin}" has no view named "${view}"`
  | UnknownCommand({plugin, command}) =>
    `baked manifest: plugin "${plugin}" has no command named "${command}"`
  }

// Views are named by component name — a view IS the surface. Commands are named
// by command name, not by the write-side component that carries them: the
// command is what a user invokes, and which slice or aggregate it lives on is an
// implementation detail the author should not have to know to curate a shop.
type selection = {
  plugin: string,
  views: option<array<string>>,
  commands: option<array<string>>,
}

let publicViews = (def: pluginStructure): array<queryableDef> =>
  Array.concat(def.readModels, def.stateViewSlices)->Array.filter(
    Platform_ComponentDefinitionsApi.isPublicQueryable,
  )

let writeSides = (def: pluginStructure): array<writableDef> =>
  Array.concat(def.stateChangeSlices, def.aggregates)

let commandNames = (def: pluginStructure): array<string> =>
  def->writeSides->Array.flatMap(w => w.commands->Array.map(c => c.name))

// Every name in the selection has to resolve. A silent no-op here ships a shell
// with a page missing for a reason no log explains — the same class of failure as
// a malformed hints file, and it gets the same treatment: fail the deploy.
let validate = (~def: pluginStructure, sel: selection): result<unit, error> => {
  let known = (names, candidates) =>
    names
    ->Option.getOr([])
    ->Array.find(name => !(candidates->Array.includes(name)))

  switch sel.views->known(def->publicViews->Array.map(q => q.name)) {
  | Some(view) => Error(UnknownView({plugin: sel.plugin, view}))
  | None =>
    switch sel.commands->known(def->commandNames) {
    | Some(command) => Error(UnknownCommand({plugin: sel.plugin, command}))
    | None => Ok()
    }
  }
}

let isSelected = (selected: option<array<string>>, name: string): bool =>
  switch selected {
  | None => true
  | Some(names) => names->Array.includes(name)
  }

// An Internal view survives the bake only when an included command references it.
// It is carried for one reason — to be a reference target — and a shell reading a
// baked manifest has no admin API to recover a missing one from, so leaving it out
// breaks the picker permanently in the one deployment shape with no fallback.
// Naming it discloses nothing: the domain API already serves that view to the same
// caller (Internal is a menu hint, not a boundary).
let referencedEntities = (~pluginName: string, kept: array<writableDef>): array<string> =>
  kept
  ->Array.flatMap(w => w.commands)
  ->Array.flatMap(c => c.references)
  ->Array.filterMap(r =>
    switch r.plugin {
    | Some(p) if Plugin.name(p) !== pluginName => None
    | _ => Some(r.entity)
    }
  )

let curateStructure = (
  ~pluginId: string,
  ~def: pluginStructure,
  sel: selection,
): result<pluginStructure, error> =>
  validate(~def, sel)->Result.map(() => {
    let pluginName = Plugin.name(pluginId)
    let keepCommands = (ws: array<writableDef>) =>
      ws
      ->Array.map(w => {...w, commands: w.commands->Array.filter(c => sel.commands->isSelected(c.name))})
      // A write side left with no command contributes no surface. Dropping it
      // keeps the curated entry a description of what the app offers rather than
      // a list of components whose commands were all removed.
      ->Array.filter(w => w.commands->Array.length > 0)

    let stateChangeSlices = def.stateChangeSlices->keepCommands
    let aggregates = def.aggregates->keepCommands
    let referenced = referencedEntities(
      ~pluginName,
      Array.concat(stateChangeSlices, aggregates),
    )
    let keepViews = (qs: array<queryableDef>) =>
      qs->Array.filter(q =>
        if Platform_ComponentDefinitionsApi.isPublicQueryable(q) {
          sel.views->isSelected(q.name)
        } else {
          referenced->Array.includes(q.name)
        }
      )

    {
      ...def,
      readModels: def.readModels->keepViews,
      stateViewSlices: def.stateViewSlices->keepViews,
      stateChangeSlices,
      aggregates,
    }
  })

// Where the file goes when the declaration does not say, and the URL a shell
// fetches it from.
//
// Both platforms write the manifest beside `config.json` at what is also the
// shell's URL root, so the key and the path the browser asks for are one string.
// Stated here, with the curation, because a platform that defaulted the key
// differently from the one that wrote `manifestUrl` would put the file where
// nothing reads it — and the symptom is an empty shop, not a missing file.
let defaultKey = "component-manifest.json"

let urlForKey = (key: option<string>): string => "/" ++ key->Option.getOr(defaultKey)

// The whole file: one entry per selection, in the order the deployment declared
// them, so the include-list also states the order a consumer reads plugins in.
let curate = (
  ~structures: array<(string, pluginStructure)>,
  ~selections: array<selection>,
): result<JSON.t, error> =>
  selections->Array.reduce(Ok([]), (acc, sel) =>
    acc->Result.flatMap(entries =>
      switch structures->Array.find(((pluginId, _)) => Plugin.name(pluginId) === sel.plugin) {
      | None => Error(UnknownPlugin(sel.plugin))
      | Some((pluginId, def)) =>
        curateStructure(~pluginId, ~def, sel)->Result.map(curated => {
          entries->Array.push(
            Platform_ComponentDefinitionsApi.encodePluginStructureEntry(~pluginId, curated),
          )
          entries
        })
      }
    )
  )->Result.map(JSON.Encode.array)
