// Pure rendering for the platform generator: union the plugins' capability
// manifests and emit the committed `PlatformCapabilities.res`.
//
// Only the derived list is generated — the platform root stays hand-written
// and reads `PlatformCapabilities.capabilities`. That keeps a requirement
// change small and entirely about capabilities in review, and it keeps the
// generator out of the business of expressing everything a real root does
// (bootstrap calls, capability handles, stack references).
//
// I/O-free so the exact bytes are testable; `PlatformGenerator` owns the file
// system.

/** One plugin's manifest, tagged with the name `deploy-manifest.yaml` lists it
    under — the name provenance comments cite. */
type pluginManifest = {
  pluginName: string,
  manifest: CapabilityManifest.t,
}

/** One declaring site, keeping which plugin's manifest carried it. */
type provenance = {
  pluginName: string,
  component: string,
  field: string,
  annotation: option<string>,
}

/** One capability the platform must provision: the qualified `{plugin}.{store}`
    key with every declaring site across every plugin. Identity is the key —
    many fields, in several plugins, legitimately name one store. */
type unionEntry = {
  kind: CapabilityManifest.kind,
  key: string,
  declaredBy: array<provenance>,
}

/** Union the manifests: entries with one key collapse to one capability, their
    provenance concatenated in manifest order. Sorted by key so the rendered
    file is deterministic. */
let union = (manifests: array<pluginManifest>): array<unionEntry> => {
  let byKey: dict<unionEntry> = Dict.make()
  manifests->Array.forEach(({pluginName, manifest}) =>
    manifest.capabilities->Array.forEach(entry => {
      let sites =
        entry.declaredBy->Array.map(site => {
          pluginName,
          component: site.component,
          field: site.field,
          annotation: site.annotation,
        })
      switch byKey->Dict.get(entry.key) {
      | Some(existing) =>
        byKey->Dict.set(entry.key, {...existing, declaredBy: existing.declaredBy->Array.concat(sites)})
      | None => byKey->Dict.set(entry.key, {kind: entry.kind, key: entry.key, declaredBy: sites})
      }
    })
  )
  byKey
  ->Dict.valuesToArray
  ->Array.toSorted((a, b) => String.compare(a.key, b.key))
}

let quote = (s: string): string => s->JSON.Encode.string->JSON.stringify

// A key is `{plugin}.{store}` by construction (`Plugin_Structure` qualifies
// every declaration). The split is at the first dot: the plugin's registered
// name cannot contain one, the store name could in principle.
let splitKey = (key: string): option<(string, string)> =>
  key
  ->String.indexOfOpt(".")
  ->Option.map(i => (
    key->String.slice(~start=0, ~end=i),
    key->String.slice(~start=i + 1),
  ))

// The provenance comment quotes the annotation as its author wrote it — taken
// from the manifest, which recorded it at the one place the owning plugin was
// unambiguous. Inferring it here is what this replaced: the manifest carries a
// deploy-manifest entry name and the key carries the registered name, and no
// rule relates the two (`platform-inspector` against `PlatformInspector` is an
// ordinary pairing), so any comparison here eventually quotes a string that is
// in no source file.
//
// A site with no recorded annotation predates the recording. It still names the
// field, which is the comment's job; it just makes no claim about the source
// text it cannot see.
let renderEntry = (entry: unionEntry): result<array<string>, string> =>
  switch splitKey(entry.key) {
  | None =>
    Error(
      `malformed capability key ${quote(entry.key)} — expected "{plugin}.{store}" (is the plugin's capabilities.json hand-edited?)`,
    )
  | Some((plugin, store)) => {
      let comments =
        entry.declaredBy->Array.map(site => {
          let site_ = `  // ${site.pluginName}: ${site.component}.${site.field}`
          switch site.annotation {
          | Some(annotation) => `${site_} @storageRef(${quote(annotation)})`
          | None => site_
          }
        })
      let line = switch entry.kind {
      | ObjectStore => `  ObjectStore({plugin: ${quote(plugin)}, store: ${quote(store)}}),`
      }
      Ok(comments->Array.concat([line]))
    }
  }

let header = [
  "// AUTO-GENERATED — do not edit. Run `pnpm run generate:platform` to update.",
  "//",
  "// The platform's capability list, unioned from the committed",
  "// `capabilities.json` manifests of the plugins deploy-manifest.yaml names.",
  "// Each entry keeps its declaring fields as provenance, so when a capability",
  "// disappears from this list, the diff says which field's change removed it.",
  "",
]

/** Render the complete `PlatformCapabilities.res`. Deterministic and
    newline-terminated: regenerating with no manifest change is byte-identical,
    so the committed file never churns. */
let render = (manifests: array<pluginManifest>): result<string, string> => {
  let entries = union(manifests)
  let rendered = entries->Array.map(renderEntry)
  switch rendered->Array.findMap(r =>
    switch r {
    | Error(e) => Some(e)
    | Ok(_) => None
    }
  ) {
  | Some(e) => Error(e)
  | None => {
      let body = if entries->Array.length == 0 {
        ["let capabilities: array<ReventlessInfra.Platform.capability> = []"]
      } else {
        ["let capabilities: array<ReventlessInfra.Platform.capability> = ["]
        ->Array.concat(rendered->Array.flatMap(r => r->Result.getOr([])))
        ->Array.concat(["]"])
      }
      Ok(header->Array.concat(body)->Array.join("\n") ++ "\n")
    }
  }
}
