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
  | UnknownDerived({plugin: string, kind: string})

/** The pages a shell builds across a plugin's views rather than from any one of
    them, as the vocabulary a deployment curates them by.

    A closed set, and deliberately kinds rather than page names. A dashboard and
    a lifecycle page are named by the framework, but a canvas is named by the
    views it draws — from that deployment's hints and the view modes its shell
    registered, neither of which this side can see. Curating by kind is the
    question this side CAN answer, and it is also the question an author is
    asking: "does this audience get calendars", not "does it get the one called
    Deliveries".

    Ordered as they appear in a menu (the dashboard tops the group, canvases and
    schedulers tail it), so the vocabulary reads as the page set it curates. */
let derivedKinds = ["dashboard", "lifecycles", "canvas", "scheduler"]

let describe = (e: error): string =>
  switch e {
  | UnknownPlugin(plugin) => `baked manifest: no registered plugin named "${plugin}"`
  | UnknownView({plugin, view}) =>
    `baked manifest: plugin "${plugin}" has no view named "${view}"`
  | UnknownCommand({plugin, command}) =>
    `baked manifest: plugin "${plugin}" has no command named "${command}"`
  | UnknownDerived({plugin, kind}) =>
    `baked manifest: plugin "${plugin}" names derived page kind "${kind}" — ` ++
    `known kinds: ${derivedKinds->Array.join(", ")}`
  }

// Views are named by component name — a view IS the surface. Commands are named
// by command name, not by the write-side component that carries them: the
// command is what a user invokes, and which slice or aggregate it lives on is an
// implementation detail the author should not have to know to curate a shop.
//
// `derived` is neither: it names page KINDS, for the reason `derivedKinds`
// gives. Unlike the other two, what it selects is not filtered here — there is
// nothing in a `pluginStructure` to filter, because the pages do not exist until
// a shell builds them. It travels to the shell instead, which is the only place
// that can honour it.
type selection = {
  plugin: string,
  views: option<array<string>>,
  commands: option<array<string>>,
  derived: option<array<string>>,
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
    | None =>
      // Against the vocabulary rather than against this plugin: a kind that
      // generates no page here is a fact about the plugin's schemas, not a
      // mistake — a shop naming `lifecycles` for a plugin whose views gain a
      // status field next month is stating an intention, and failing it would
      // punish the deployment for being early.
      switch sel.derived->known(derivedKinds) {
      | Some(kind) => Error(UnknownDerived({plugin: sel.plugin, kind}))
      | None => Ok()
      }
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

/**
 File name for a journey that did not choose one.

 Derived from the group so two journeys cannot collide by accident, and
 lower-cased with non-alphanumerics folded to `-` because a group name is a
 Cognito identifier and a key is part of a URL. A deployment wanting something
 else names it.
 */
let journeyKey = (~group: string): string => {
  let slug =
    group
    ->String.toLowerCase
    ->String.split("")
    ->Array.map(c =>
      switch c {
      | "a" | "b" | "c" | "d" | "e" | "f" | "g" | "h" | "i" | "j" | "k" | "l" | "m" => c
      | "n" | "o" | "p" | "q" | "r" | "s" | "t" | "u" | "v" | "w" | "x" | "y" | "z" => c
      | "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" => c
      | _ => "-"
      }
    )
    ->Array.join("")
  `component-manifest-${slug}.json`
}

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
            Platform_ComponentDefinitionsApi.encodePluginStructureEntry(
              ~pluginId,
              ~derived=?sel.derived,
              curated,
            ),
          )
          entries
        })
      }
    )
  )->Result.map(JSON.Encode.array)
